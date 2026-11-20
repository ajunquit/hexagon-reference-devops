Set-StrictMode -Version Latest

# The local topology of each messaging provider (docs/separacion-por-nube.md): a module named
# <Provider>LocalMessaging.psm1 next to this one declares its logical provider and implements the
# LocalMessaging* functions inside it. Each DevOps template brings the emulators of its cloud.
$script:providers = $null

function Get-LocalMessagingProviderModule([string] $Provider) {
    if ($null -eq $script:providers) {
        $script:providers = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*LocalMessaging.psm1' -File | Where-Object Name -CNE 'LocalMessaging.psm1' |
            Sort-Object Name | ForEach-Object { Import-Module $_.FullName -PassThru -DisableNameChecking })
    }
    $matching = @($script:providers | Where-Object { (& $_ { Get-LocalMessagingProvider }) -ceq $Provider })
    if ($matching.Count -ne 1) { throw "Unsupported messaging provider '$Provider'." }
    return $matching[0]
}

function Invoke-LocalMessagingProvider([Management.Automation.PSModuleInfo] $Module, [string] $Name, [object[]] $Arguments = @()) {
    return & $Module { param($command, $values) & $command @values } $Name $Arguments
}

function Get-LocalMessagingManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $BackendPath
    )

    $backendRoot = (Resolve-Path -LiteralPath $BackendPath).Path
    $manifestPath = Join-Path $backendRoot '.hexagon/messaging-requirements.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Backend messaging manifest is missing: $manifestPath"
    }

    $json = Get-Content -Raw -LiteralPath $manifestPath
    $manifest = $json | ConvertFrom-Json
    $schemaReference = [string] $manifest.'$schema'
    if ($schemaReference -notmatch '^(?!/)(?!.*(?:^|[\\/])\.\.(?:[\\/]|$))[A-Za-z0-9._/\\-]+$') {
        throw "Backend manifest schema reference '$schemaReference' is not a safe relative path."
    }

    $schemaPath = [IO.Path]::GetFullPath(
        (Join-Path (Split-Path -Parent $manifestPath) $schemaReference)
    )
    if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
        throw "Backend messaging schema is missing: $schemaPath"
    }
    if (-not ($json | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
        throw "Backend manifest '$manifestPath' does not satisfy its schema."
    }

    $destinationIds = @($manifest.destinations | ForEach-Object { [string] $_.id })
    if (@($destinationIds | Select-Object -Unique).Count -ne $destinationIds.Count) {
        throw 'Backend messaging destination ids must be unique.'
    }
    $consumerIds = @($manifest.consumers | ForEach-Object { [string] $_.id })
    if (@($consumerIds | Select-Object -Unique).Count -ne $consumerIds.Count) {
        throw 'Backend messaging consumer ids must be unique.'
    }
    foreach ($consumer in $manifest.consumers) {
        if ([string] $consumer.destination -notin $destinationIds) {
            throw "Consumer '$($consumer.id)' references unknown destination '$($consumer.destination)'."
        }
    }

    return [pscustomobject] @{
        BackendRoot = $backendRoot
        Manifest    = $manifest
    }
}

function Assert-LocalMessagingPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Manifest,

        [Parameter(Mandatory = $true)]
        [pscustomobject] $Policy
    )

    $expectedKind = Invoke-LocalMessagingProvider (Get-LocalMessagingProviderModule ([string] $Manifest.provider)) Get-LocalMessagingTopologyKind
    if ([string] $Policy.kind -cne $expectedKind) {
        throw "Policy kind '$($Policy.kind)' does not match provider '$($Manifest.provider)'."
    }
    if ([string] $Policy.product -cne [string] $Manifest.product) {
        throw "Policy product '$($Policy.product)' does not match backend product '$($Manifest.product)'."
    }

    foreach ($collectionName in @('destinations', 'consumers')) {
        $manifestIds = @($Manifest.$collectionName | ForEach-Object { [string] $_.id } | Sort-Object)
        $policyIds = @($Policy.$collectionName | ForEach-Object { [string] $_.id } | Sort-Object)
        if (($manifestIds -join "`n") -cne ($policyIds -join "`n")) {
            throw "Policy $collectionName must match the backend manifest exactly."
        }
    }
}

function New-LocalMessagingPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Manifest,
        [AllowNull()]
        [pscustomobject] $Policy
    )

    if ($null -ne $Policy) {
        Assert-LocalMessagingPolicy -Manifest $Manifest -Policy $Policy
    }
    $providerPlan = Invoke-LocalMessagingProvider (Get-LocalMessagingProviderModule ([string] $Manifest.provider)) ConvertTo-ProviderLocalMessaging @($Manifest, $Policy)
    $bindings = [ordered] @{
        apiVersion = 'hexagon.ec/local-messaging-bindings/v1'
        kind       = 'LocalMessagingBindings'
        product    = [string] $Manifest.product
        provider   = [string] $Manifest.provider
        workloads  = $providerPlan.Workloads
    }
    return [pscustomobject] @{
        Bindings = $bindings
        Files    = $providerPlan.Files
    }
}

Export-ModuleMember -Function @(
    'Assert-LocalMessagingPolicy',
    'Get-LocalMessagingManifest',
    'New-LocalMessagingPlan',
    'Get-LocalMessagingProviderModule',
    'Invoke-LocalMessagingProvider'
)
