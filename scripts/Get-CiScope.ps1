<#
.SYNOPSIS
    Decides which messaging providers the CI of this repository tests.

.DESCRIPTION
    Writes `messaging-matrix` (the include list of the messaging-integration job),
    `messaging-enabled` and `integrations` to GITHUB_OUTPUT, or prints them without -GitHubOutput. The
    template tests every provider; a product tests only the provider its backend declares in its
    pinned manifest. `integrations` is false when the changes since -BaseCommit cannot alter the broker
    or PostgreSQL results; without a usable base commit every integration runs.
#>
[CmdletBinding()]
param(
    [switch] $GitHubOutput,

    # The commit the change is compared with: the pull request base or the previous main commit.
    [string] $BaseCommit
)

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

$changedPaths = $null
if ($BaseCommit -cmatch '^[0-9a-f]{40}$' -and $BaseCommit -cne ('0' * 40)) {
    $diff = @(& git -C $repositoryRoot diff --name-only $BaseCommit HEAD 2>$null)
    if ($LASTEXITCODE -eq 0) { $changedPaths = [string[]] $diff }
}
$integrations = if (Test-CiIntegrationChange -ChangedPaths $changedPaths) { 'true' } else { 'false' }

if ($GitHubOutput) {
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "messaging-matrix=$matrix"
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "messaging-enabled=$enabled"
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "integrations=$integrations"
}
Write-Host "Messaging providers under test: $(if ($providers.Count -gt 0) { $providers -join ', ' } else { 'none' })"
Write-Host "Integration jobs needed: $integrations$(if ($null -eq $changedPaths) { ' (no comparable base commit)' })"
