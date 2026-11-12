<#
.SYNOPSIS
    Decides which messaging providers the CI of this repository tests.

.DESCRIPTION
    Writes `messaging-matrix` (the include list of the messaging-integration job) and
    `messaging-enabled` to GITHUB_OUTPUT, or prints them without -GitHubOutput. The template tests every
    provider; a product tests only the provider its backend declares in its pinned manifest.
#>
[CmdletBinding()]
param([switch] $GitHubOutput)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'ApplicationContracts.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CiScope.psm1') -Force

$providers = Get-CiMessagingProviders -Root $repositoryRoot -ReadManifest {
    param($repository, $commit, $path, $product)
    Get-ValidatedApplicationManifest -Repository $repository -Commit $commit -Path $path -ExpectedProduct $product -ExpectedComponent 'backend'
}
$matrix = ConvertTo-CiMessagingMatrix -Providers $providers
$enabled = if ($providers.Count -gt 0) { 'true' } else { 'false' }

if ($GitHubOutput) {
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "messaging-matrix=$matrix"
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "messaging-enabled=$enabled"
}
Write-Host "Messaging providers under test: $(if ($providers.Count -gt 0) { $providers -join ', ' } else { 'none' })"
