<#
.SYNOPSIS
    Coordinates a reviewed Genesis/Apocalypse stage using the native lifecycle adapter.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][ValidateSet('Create', 'Destroy')][string] $Operation,
    [Parameter(Mandatory)][ValidateSet('Validate', 'Prepare', 'Apply', 'Sync', 'Quiesce')][string] $Mode,
    [Parameter(Mandatory)][ValidateSet('dev', 'staging', 'prod')][string] $Environment,
    [Parameter(Mandatory)][string] $InstanceId,
    [Parameter(Mandatory)][string] $DefinitionSha256,
    [ValidateSet('hosting', 'messaging')][string] $RootId = 'hosting',
    [string] $ReviewSha256,
    [string] $Confirmation
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'EnvironmentWorkflow.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'EphemeralEnvironment.psm1')
Import-Module (Join-Path $PSScriptRoot 'EnvironmentLifecycle.psm1')
Import-Module (Join-Path $PSScriptRoot 'AzureEnvironmentStore.psm1')
Import-Module (Join-Path $PSScriptRoot 'LifecycleNative.psm1')
Import-Module (Join-Path $PSScriptRoot 'PlatformBootstrap.psm1')
$status = 'Blocked'; $code = $null; $details = @{}
try {
    $repository = Split-Path -Parent $PSScriptRoot
    $definitionPath = Join-Path $repository ".config/environments/$Environment/$InstanceId/definition.json"
    $definition = Assert-EphemeralTrackedDefinition $definitionPath $DefinitionSha256 $Environment $InstanceId $Operation
    $inventory = $definition.inventory
    if ($WhatIfPreference) { $status = 'Unverified' }
    elseif ($PSCmdlet.ShouldProcess("$($inventory.product)/$Environment/$InstanceId", "$Mode $Operation stage")) {
        $expectedWorkflow = $(if ($Operation -ceq 'Create') { 'genesis' } else { 'apocalypse' })
        if ($env:GITHUB_ACTIONS -cne 'true' -or $env:GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or $env:GITHUB_REF -cne 'refs/heads/main' -or
            $env:GITHUB_REPOSITORY -ine $inventory.iac.repository -or $env:GITHUB_WORKFLOW_REF -cne "$($inventory.iac.repository)/.github/workflows/$expectedWorkflow.yml@refs/heads/main") { throw 'lifecycle.azure.trustedWorkflowRequired' }
        Assert-EphemeralRepository $definition
        $githubEnvironment = Get-EphemeralGithubProtection $definition -SkipBindings
        if ($Mode -ceq 'Validate') {
            $details = @{ clientId = $inventory.target.clientId; tenantId = $inventory.target.tenantId; subscriptionId = $inventory.target.subscriptionId; githubEnvironment = $githubEnvironment }
            $status = 'Validated'
        }
        else {
            foreach ($pair in @{ AZURE_CLIENT_ID = $inventory.target.clientId; AZURE_TENANT_ID = $inventory.target.tenantId; AZURE_SUBSCRIPTION_ID = $inventory.target.subscriptionId }.GetEnumerator()) {
                if ([Environment]::GetEnvironmentVariable($pair.Key) -ine $pair.Value) { throw 'lifecycle.ephemeral.githubVariableDrift' }
            }
            $directory = New-EphemeralWorkspace (Join-Path $repository "artifacts/lifecycle-$([guid]::NewGuid().ToString('N'))") -Confirm:$false
            $initialPath = Join-Path $directory 'initial-inventory.json'
            [IO.File]::WriteAllText($initialPath, (ConvertTo-PlatformBootstrapJson $inventory) + "`n")
            $workspace = Join-Path $directory 'work'
            $entry = Join-Path $PSScriptRoot 'Invoke-AzureEnvironment.ps1'
            $profileDirectory = Split-Path -Parent $definitionPath
            $port = {
                param($action)
                if ($action -ceq 'Probe') {
                    $context = New-AzureLifecycleContext $inventory
                    try {
                        Enter-AzureLifecycleLease $context -Confirm:$false
                        $journal = Get-AzureLifecycleJournal $context
                        return @{ status = 'Probed'; inventory = $(if ($null -eq $journal) { $null } else { $journal.inventory }) }
                    }
                    finally { Exit-AzureLifecycleLease $context -Confirm:$false }
                }
                if ($action -ceq 'ValidateSources') {
                    foreach ($pair in @(@('descriptor.json', $inventory.descriptorSha256), @('release.json', $inventory.releaseSha256))) {
                        $path = Join-Path $profileDirectory $pair[0]
                        if ((Get-LifecycleFileHash $path) -cne $pair[1]) { throw 'lifecycle.ephemeral.sourceMetadataChanged' }
                    }
                    $previousToken = $env:GH_TOKEN
                    try {
                        if ($env:HEXAGON_APPLICATIONS_READ_TOKEN) { $env:GH_TOKEN = $env:HEXAGON_APPLICATIONS_READ_TOKEN }
                        & (Join-Path $PSScriptRoot 'Test-ApplicationRelease.ps1') -Descriptor (Join-Path $profileDirectory 'descriptor.json') -Release (Join-Path $profileDirectory 'release.json') -VerifySources | Out-Null
                    }
                    finally { $env:GH_TOKEN = $previousToken }
                    return @{ status = 'SourcesValidated' }
                }
                $path = $(if ($action -cin @('Build', 'Restore')) { $initialPath } else { Join-Path $workspace 'inventory.json' })
                $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $entry, '-Mode', $action, '-Inventory', $path, '-Environment', $Environment, '-InstanceId', $InstanceId, '-Workspace', $workspace, '-RootId', $RootId, '-Operation', $Operation)
                if ($action -ceq 'Build') { $arguments += @('-InputDirectory', (Join-Path $profileDirectory 'inputs')) }
                if ($action -cin @('Apply', 'Quiesce')) { $arguments += @('-Confirmation', $Confirmation) }
                if ($action -ceq 'Apply') { $arguments += @('-ReviewSha256', $ReviewSha256) }
                $native = Invoke-LifecycleCommand pwsh $arguments $repository -TimeoutSeconds 1800
                try { $response = $native.text | ConvertFrom-Json -AsHashtable -Depth 16 }
                catch { throw 'lifecycle.ephemeral.adapterResultInvalid' }
                if ($response.apiVersion -cne 'hexagon.ec/azure-environment-result/v1' -or $response.applicationVerified -isnot [bool] -or $response.applicationVerified -ne $false) { throw 'lifecycle.ephemeral.adapterResultInvalid' }
                if ($native.exitCode -ne 0 -and $response.status -cne 'Failed') {
                    if ($response.code -cmatch '^lifecycle[.][A-Za-z0-9.]+$') { throw $response.code }
                    throw 'lifecycle.ephemeral.adapterFailed'
                }
                return $response
            }
            $result = Invoke-EphemeralStage $definition $Operation $Mode $RootId $ReviewSha256 $Confirmation $port -Confirm:$false
            $status = $result.status
            if ($result.ContainsKey('details')) { $details = $result.details }
            if ($env:GITHUB_STEP_SUMMARY) {
                $summary = "Operation: $Operation; environment: $Environment; instance: $InstanceId; root: $RootId; status: $status.`n"
                if ($details.ContainsKey('reviewSha256')) { $summary += "Reviewed plan hash: $($details.reviewSha256)`nApply requires a separate dispatch after reviewing the private plan in Blob.`n" }
                $summary += "Application verification: pending. Inventory and private plans remain in the instance Blob container.`n"
                Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summary
            }
        }
    }
}
catch { $status = 'Blocked'; $code = $(if ($_.Exception.Message -cmatch '^lifecycle[.][A-Za-z0-9.]+$') { $_.Exception.Message } else { 'lifecycle.ephemeral.workflowFailed' }) }
$json = @{ apiVersion = 'hexagon.ec/environment-workflow-result/v1'; status = $status; operation = $Operation; mode = $Mode; rootId = $RootId; applicationVerified = $false; details = $details; code = $code } | ConvertTo-Json -Depth 8
if (-not ($json | Test-Json -SchemaFile (Join-Path $repository 'contracts/schemas/environment-workflow-result-v1.schema.json') -ErrorAction SilentlyContinue)) { throw 'lifecycle.ephemeral.resultInvalid' }
$json
if ($status -cin @('Blocked', 'Failed')) { exit 1 }; if ($status -ceq 'Unverified') { exit 2 }; exit 0
