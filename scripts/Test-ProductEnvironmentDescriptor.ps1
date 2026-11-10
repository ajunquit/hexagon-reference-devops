<#
.SYNOPSIS
    Validates a Hexagon ProductEnvironment descriptor.

.DESCRIPTION
    Validates the local JSON Schema, uniqueness and canonical location. With VerifySources, it also
    downloads every manifest from its pinned GitHub commit, validates the application schema and
    compares the exact SHA-256.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Descriptor,

    [switch] $VerifySources
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$schemaPath = Join-Path $repositoryRoot 'contracts/schemas/product-environment-v1.schema.json'
$descriptorPath = (Resolve-Path -LiteralPath $Descriptor).Path

Import-Module (Join-Path $PSScriptRoot 'ApplicationContracts.psm1') -Force

$json = Get-Content -Raw -LiteralPath $descriptorPath
$isValid = $json | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue
if (-not $isValid) {
    throw "Descriptor '$descriptorPath' does not satisfy ProductEnvironment v1."
}

$model = $json | ConvertFrom-Json
$componentNames = @($model.components | ForEach-Object { [string] $_.name })
$duplicateComponents = @(
    $componentNames |
        Group-Object |
        Where-Object Count -gt 1 |
        ForEach-Object Name
)
if ($duplicateComponents.Count -gt 0) {
    throw "Duplicate component names: $($duplicateComponents -join ', ')."
}

foreach ($component in $model.components) {
    $manifestPaths = @($component.manifests | ForEach-Object { [string] $_.path })
    $duplicates = @(
        $manifestPaths |
            Group-Object |
            Where-Object Count -gt 1 |
            ForEach-Object Name
    )
    if ($duplicates.Count -gt 0) {
        throw "Component '$($component.name)' repeats manifests: $($duplicates -join ', ')."
    }
}

$relativePath = [IO.Path]::GetRelativePath($repositoryRoot, $descriptorPath).Replace('\', '/')
if ($relativePath.StartsWith('products/', [StringComparison]::Ordinal)) {
    $expectedPath = "products/$($model.product)/environments/$($model.environment)/descriptor.json"
    if ($relativePath -cne $expectedPath) {
        throw "Descriptor location '$relativePath' must be '$expectedPath'."
    }
}

if ($VerifySources) {
    foreach ($component in $model.components) {
        foreach ($manifest in $component.manifests) {
            $verified = Get-ValidatedApplicationManifest `
                -Repository ([string] $component.repository) `
                -Commit ([string] $component.commit) `
                -Path ([string] $manifest.path) `
                -ExpectedProduct ([string] $model.product) `
                -ExpectedComponent ([string] $component.name)

            if ($verified.Sha256 -cne [string] $manifest.sha256) {
                throw "SHA-256 mismatch for '$($component.repository):$($manifest.path)' at " +
                    "'$($component.commit)'."
            }
        }
    }
}

$sourceStatus = if ($VerifySources) { ' and remote sources' } else { '' }
Write-Host "Validated descriptor${sourceStatus}: $relativePath"
