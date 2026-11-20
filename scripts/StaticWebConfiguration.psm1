Set-StrictMode -Version Latest

function ConvertTo-StaticWebConfiguration {
    param($Manifest, $Outputs)
    if ($Manifest.apiVersion -cne 'hexagon.ec/frontend-hosting-requirements/v2' -or $Manifest.artifact.type -cne 'static-spa' -or $Manifest.routing.fallback -cne '/index.html' -or $Manifest.runtimeConfiguration.path -cne '/runtime-config.json' -or $Manifest.runtimeConfiguration.visibility -cne 'public') { throw 'Unsupported frontend hosting contract.' }
    $bindings = @($Manifest.runtimeConfiguration.bindings)
    if ($bindings.Count -ne 2 -or @($bindings | Where-Object { $_.key -ceq 'apiUrl' -and $_.source -ceq 'product-api' -and $_.type -ceq 'public-url' -and $_.required }).Count -ne 1 -or @($bindings | Where-Object { $_.key -ceq 'authentication' -and $_.source -ceq 'hexagon-auth' -and $_.type -ceq 'oidc-public-client' -and $_.required }).Count -ne 1) { throw 'Unsupported public bindings.' }
    $apiUrl = [string] $Outputs.api_url.value
    $auth = $Outputs.frontend_authentication.value
    $api = $null
    $authority = $null
    if (-not [Uri]::TryCreate($apiUrl, [UriKind]::Absolute, [ref] $api) -or $api.Scheme -cne 'https' -or $api.UserInfo -or $api.Query -or $api.Fragment -or $api.AbsolutePath -cne '/api/v1') { throw 'A deployed HTTPS /api/v1 endpoint is required.' }
    if (-not [Uri]::TryCreate([string] $auth.authority, [UriKind]::Absolute, [ref] $authority) -or $authority.Scheme -cne 'https' -or $authority.UserInfo -or $authority.Query -or $authority.Fragment -or $authority.AbsoluteUri.EndsWith('/')) { throw 'Invalid HTTPS authority.' }
    if ([string] $auth.clientId -cnotmatch '^[A-Za-z0-9._-]+$' -or [string] $auth.scope -cnotmatch '^[A-Za-z0-9_.:-]+(?: [A-Za-z0-9_.:-]+)*$' -or 'openid' -cnotin ($auth.scope -split ' ')) { throw 'Invalid public OIDC client.' }
    # Select only declared public fields. Terraform outputs may contain unrelated sensitive values.
    return @{
        'runtime-config.json' = @{ apiUrl = $apiUrl; authentication = @{ authority = [string] $auth.authority; clientId = [string] $auth.clientId; scope = [string] $auth.scope } }
    }
}

# The host of each cloud lives in a module named *WebHost.psm1 next to this one: it declares the files
# that only the host reads (never part of a bundle, never verified as public content) and the
# default public hosts that the serving checks accept. The modules export nothing to the caller.
$script:webHosts = $null

function Get-StaticWebHostModules {
    if ($null -eq $script:webHosts) {
        $script:webHosts = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*WebHost.psm1' -File | Sort-Object Name |
            ForEach-Object { Import-Module $_.FullName -PassThru -DisableNameChecking })
    }
    return $script:webHosts
}

function Get-StaticWebReservedNames {
    return @(@('hexagon-deployment.json', 'runtime-config.json') + @(Get-StaticWebHostModules | ForEach-Object { & $_ { Get-WebHostReservedNames } }))
}

function Test-StaticWebOrigin([string] $HostName) {
    return @(Get-StaticWebHostModules | Where-Object { & $_ { param($h) Test-WebHostOrigin $h } $HostName }).Count -gt 0
}

Export-ModuleMember -Function ConvertTo-StaticWebConfiguration, Get-StaticWebReservedNames, Test-StaticWebOrigin
