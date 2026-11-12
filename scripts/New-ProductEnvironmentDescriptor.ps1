<#
.SYNOPSIS
    Pins application contracts for one Hexagon product environment.

.DESCRIPTION
    Resolves optional frontend and backend references to full GitHub commits, validates their
    deployment manifests and writes a ProductEnvironment v1 descriptor with exact SHA-256 values.

    Repository and reference parameters must be provided in pairs. At least one component is
    required. The command supports WhatIf and performs no GitHub reads when WhatIf declines the
    operation.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^hexagon-[a-z][a-z0-9-]*$')]
    [string] $Product,

    [Parameter(Mandatory = $true)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string] $Environment,

    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string] $BackendRepository,

    [string] $BackendRef,

    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string] $FrontendRepository,

    [string] $FrontendRef,

    [switch] $IncludeBackendHosting,
    [switch] $WithoutBackendMessaging,
    [switch] $IncludeAcceptance
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$schemaPath = Join-Path $repositoryRoot 'contracts/schemas/product-environment-v1.schema.json'
$targetPath = Join-Path `
    $repositoryRoot `
    "products/$Product/environments/$Environment/descriptor.json"

Import-Module (Join-Path $PSScriptRoot 'ApplicationContracts.psm1') -Force

$hasBackendRepository = -not [string]::IsNullOrWhiteSpace($BackendRepository)
$hasBackendRef = -not [string]::IsNullOrWhiteSpace($BackendRef)
$hasFrontendRepository = -not [string]::IsNullOrWhiteSpace($FrontendRepository)
$hasFrontendRef = -not [string]::IsNullOrWhiteSpace($FrontendRef)

if ($hasBackendRepository -ne $hasBackendRef) {
    throw 'BackendRepository and BackendRef must be provided together.'
}
if ($IncludeBackendHosting -and -not $hasBackendRepository) {
    throw 'IncludeBackendHosting requires a backend component.'
}
if ($WithoutBackendMessaging -and (-not $hasBackendRepository -or -not $IncludeBackendHosting)) {
    throw 'WithoutBackendMessaging requires a pinned backend hosting contract.'
}
if ($hasFrontendRepository -ne $hasFrontendRef) {
    throw 'FrontendRepository and FrontendRef must be provided together.'
}
if (-not $hasBackendRepository -and -not $hasFrontendRepository) {
    throw 'At least one frontend or backend component is required.'
}
if ($IncludeAcceptance -and $hasBackendRepository -and -not $IncludeBackendHosting) {
    throw 'IncludeAcceptance requires IncludeBackendHosting for a backend component.'
}

$operation = "resolve application contracts and write $targetPath"
if (-not $PSCmdlet.ShouldProcess($Product, $operation)) {
    return
}

$components = [Collections.Generic.List[object]]::new()

if ($hasFrontendRepository) {
    $commit = Resolve-GitHubCommit -Repository $FrontendRepository -Reference $FrontendRef
    $path = '.hexagon/frontend-hosting-requirements.json'
    $validated = Get-ValidatedApplicationManifest `
        -Repository $FrontendRepository `
        -Commit $commit `
        -Path $path `
        -ExpectedProduct $Product `
        -ExpectedComponent 'web'
    $components.Add([ordered] @{
        name       = 'web'
        repository = $FrontendRepository
        commit     = $commit
        manifests  = @(
            [ordered] @{
                path   = $path
                sha256 = $validated.Sha256
            }
        )
    })
}

if ($hasBackendRepository) {
    $commit = Resolve-GitHubCommit -Repository $BackendRepository -Reference $BackendRef
    $manifests = @()
    if (-not $WithoutBackendMessaging) {
        $path = '.hexagon/messaging-requirements.json'
        $validated = Get-ValidatedApplicationManifest -Repository $BackendRepository -Commit $commit `
            -Path $path -ExpectedProduct $Product -ExpectedComponent 'backend'
        $manifests += [ordered] @{ path = $path; sha256 = $validated.Sha256 }
    }
    if ($IncludeBackendHosting) {
        $hostingPath = '.hexagon/backend-hosting-requirements.json'
        $hosting = Get-ValidatedApplicationManifest -Repository $BackendRepository -Commit $commit `
            -Path $hostingPath -ExpectedProduct $Product -ExpectedComponent 'backend'
        $manifests += [ordered] @{ path = $hostingPath; sha256 = $hosting.Sha256 }
    }
    $components.Add([ordered] @{
        name       = 'backend'
        repository = $BackendRepository
        commit     = $commit
        manifests  = $manifests
    })
}

if ($IncludeAcceptance) {
    foreach ($component in $components) {
        $path = '.hexagon/acceptance-requirements.json'
        $acceptance = Get-ValidatedApplicationManifest -Repository $component.repository -Commit $component.commit `
            -Path $path -ExpectedProduct $Product -ExpectedComponent $component.name
        if (-not (($acceptance.Manifest | ConvertTo-Json -Depth 12) | Test-Json -SchemaFile (Join-Path $repositoryRoot 'contracts/schemas/acceptance-requirements-v1.schema.json') -ErrorAction SilentlyContinue)) { throw 'Unsupported acceptance requirements.' }
        $component.manifests += [ordered] @{ path = $path; sha256 = $acceptance.Sha256 }
    }
}

$descriptor = [ordered] @{
    '$schema'   = '../../../../contracts/schemas/product-environment-v1.schema.json'
    apiVersion = 'hexagon.ec/product-environment/v1'
    kind        = 'ProductEnvironment'
    product     = $Product
    environment = $Environment
    components  = @($components)
}
$json = $descriptor | ConvertTo-Json -Depth 8
$isValid = $json | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue
if (-not $isValid) {
    throw 'Generated descriptor does not satisfy ProductEnvironment v1.'
}

$targetDirectory = Split-Path -Parent $targetPath
[IO.Directory]::CreateDirectory($targetDirectory) | Out-Null
$temporaryPath = "$targetPath.$([guid]::NewGuid().ToString('N')).tmp"
try {
    [IO.File]::WriteAllText(
        $temporaryPath,
        $json + "`n",
        [Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporaryPath -Destination $targetPath -Force
}
finally {
    if (Test-Path -LiteralPath $temporaryPath) {
        Remove-Item -LiteralPath $temporaryPath -Force
    }
}

& (Join-Path $PSScriptRoot 'Test-ProductEnvironmentDescriptor.ps1') `
    -Descriptor $targetPath `
    -VerifySources

Write-Host "Wrote immutable application contract descriptor: $targetPath"
