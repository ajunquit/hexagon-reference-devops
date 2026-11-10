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
        'staticwebapp.config.json' = @{
            navigationFallback = @{ rewrite = '/index.html'; exclude = @('/runtime-config.json', '/assets/*', '/*.{css,js,map,ico,png,svg,woff,woff2}') }
            globalHeaders = @{ 'Cache-Control' = 'no-cache'; 'X-Content-Type-Options' = 'nosniff'; 'Referrer-Policy' = 'no-referrer' }
            routes = @(@{ route = '/runtime-config.json'; headers = @{ 'Cache-Control' = 'no-store' } }, @{ route = '/index.html'; headers = @{ 'Cache-Control' = 'no-store' } })
        }
    }
}

Export-ModuleMember -Function ConvertTo-StaticWebConfiguration
