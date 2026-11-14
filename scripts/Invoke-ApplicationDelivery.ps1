<#
.SYNOPSIS
    Delivers immutable 9B candidates and coordinates reviewed maintenance and backend activation.
.DESCRIPTION
    The provider comes from the target of the tracked definition: Azure, or AWS (ADR 0025). The stages
    are the same; DatabaseCredentials exists only on AWS (ADR 0024).
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][ValidateSet('dev', 'staging', 'prod')][string] $Environment,
    [Parameter(Mandatory)][string] $InstanceId,
    [Parameter(Mandatory)][string] $DefinitionSha256,
    [Parameter(Mandatory)][string] $DeliverySha256,
    [Parameter(Mandatory)][ValidateSet('Validate', 'Artifacts', 'PrepareMaintenance', 'ApplyMaintenance', 'DatabaseCredentials', 'KeycloakDatabase', 'PrepareIdentity', 'ApplyIdentity', 'Migrations', 'DatabaseAccess', 'PrepareActivation', 'ApplyActivation', 'PublishWeb', 'VerifyServing', 'PrepareAcceptance', 'Acceptance')][string] $Stage,
    [string] $ReviewSha256, [string] $Confirmation
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($name in @('PlatformBootstrap', 'EnvironmentLifecycle', 'EnvironmentSnapshot', 'EphemeralEnvironment', 'AzureEnvironmentStore', 'AwsEnvironmentStore', 'LifecycleNative', 'ApplicationArtifacts', 'AzureApplicationDelivery', 'AwsApplicationDelivery')) {
    Import-Module (Join-Path $PSScriptRoot "$name.psm1")
}
$context = $null; $aws = $false; $status = 'Blocked'; $code = $null; $details = @{}
try {
    $repository = Split-Path -Parent $PSScriptRoot
    $profile = Join-Path $repository ".config/environments/$Environment/$InstanceId"
    $definition = Assert-EphemeralTrackedDefinition (Join-Path $profile 'definition.json') $DefinitionSha256 $Environment $InstanceId Create
    $inventory = $definition.inventory
    $aws = $inventory.target.ContainsKey('accountId')
    if ($Stage -ceq 'DatabaseCredentials' -and -not $aws) { throw 'lifecycle.delivery.stageUnsupported' }
    $deliveryPath = Join-Path $profile 'delivery.json'; $releasePath = Join-Path $profile 'release.json'; $descriptorPath = Join-Path $profile 'descriptor.json'
    if ($DeliverySha256 -cnotmatch '^[0-9a-f]{64}$' -or (Get-LifecycleFileHash $deliveryPath) -cne $DeliverySha256 -or
        (Get-LifecycleFileHash $releasePath) -cne $inventory.releaseSha256 -or (Get-LifecycleFileHash $descriptorPath) -cne $inventory.descriptorSha256) { throw 'lifecycle.delivery.metadataChanged' }
    $tracked = Invoke-LifecycleCommand git @('show', "HEAD:.config/environments/$Environment/$InstanceId/delivery.json") $repository -TimeoutSeconds 30
    if ($tracked.exitCode -ne 0 -or (Get-LifecycleBytesHash $tracked.bytes) -cne $DeliverySha256) { throw 'lifecycle.delivery.definitionNotTracked' }
    $delivery = Get-Content -Raw -LiteralPath $deliveryPath | ConvertFrom-Json -AsHashtable -Depth 20
    $release = Get-Content -Raw -LiteralPath $releasePath | ConvertFrom-Json -AsHashtable -Depth 32
    Assert-ApplicationDelivery $delivery $inventory.releaseSha256
    & (Join-Path $PSScriptRoot 'Test-ApplicationRelease.ps1') -Descriptor $descriptorPath -Release $releasePath | Out-Null
    if ($WhatIfPreference) { $status = 'Unverified' }
    elseif ($PSCmdlet.ShouldProcess("$($inventory.product)/$Environment/$InstanceId", "Run delivery stage $Stage")) {
        if ($env:GITHUB_ACTIONS -cne 'true' -or $env:GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or $env:GITHUB_REF -cne 'refs/heads/main' -or
            $env:GITHUB_REPOSITORY -cne $inventory.iac.repository -or $env:GITHUB_WORKFLOW_REF -cne "$($inventory.iac.repository)/.github/workflows/delivery.yml@refs/heads/main") { throw 'lifecycle.azure.trustedWorkflowRequired' }
        Assert-EphemeralRepository $definition
        $githubEnvironment = Get-EphemeralGithubProtection $definition -SkipBindings
        if ($Stage -ceq 'Validate') {
            $details = $(if ($aws) { @{ provider = 'aws'; accountId = $inventory.target.accountId; region = $inventory.target.region; roleArn = $inventory.target.roleArn; githubEnvironment = $githubEnvironment } }
                else { @{ provider = 'azure'; clientId = $inventory.target.clientId; tenantId = $inventory.target.tenantId; subscriptionId = $inventory.target.subscriptionId; githubEnvironment = $githubEnvironment } })
            $status = 'Validated'
        }
        else {
            foreach ($pair in (Get-EphemeralGithubBindings $definition).GetEnumerator()) {
                if ([Environment]::GetEnvironmentVariable($pair.Key) -ine $pair.Value) { throw 'lifecycle.ephemeral.githubVariableDrift' }
            }
            $parent = New-EphemeralWorkspace (Join-Path $repository "artifacts/delivery-$([guid]::NewGuid().ToString('N'))") -Confirm:$false
            $initialPath = Join-Path $parent 'initial-inventory.json'
            [IO.File]::WriteAllText($initialPath, (ConvertTo-PlatformBootstrapJson $inventory) + "`n")
            $workspace = Join-Path $parent 'work'
            $restore = Invoke-LifecycleCommand pwsh @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot $(if ($aws) { 'Invoke-AwsEnvironment.ps1' } else { 'Invoke-AzureEnvironment.ps1' })), '-Mode', 'Restore', '-Inventory', $initialPath, '-Environment', $Environment, '-InstanceId', $InstanceId, '-Workspace', $workspace) $repository -TimeoutSeconds 180
            if ($restore.exitCode -ne 0) { throw 'lifecycle.delivery.restoreFailed' }
            $restored = Read-EnvironmentInventory (Join-Path $workspace 'inventory.json')
            if ($aws) {
                Assert-LifecycleCliEnvironment
                $caller = Invoke-LifecycleCommand aws @('sts', 'get-caller-identity', '--region', $restored.target.region, '--output', 'json') -TimeoutSeconds 45
                if ($caller.exitCode -ne 0) { throw 'lifecycle.aws.accountUnavailable' }
                $identity = $caller.text | ConvertFrom-Json -AsHashtable
                $context = New-AwsLifecycleContext $restored $identity.Arn $identity.Account
                Enter-AwsLifecycleLease $context -Confirm:$false
                $remote = Get-AwsLifecycleJournal $context
                if ($null -eq $remote -or $context.remoteHash -cne (Get-LifecycleFileHash (Join-Path $workspace 'inventory.json'))) { throw 'lifecycle.aws.localJournalStale' }
            }
            else {
                $context = New-AzureLifecycleContext $restored
                Enter-AzureLifecycleLease $context -Confirm:$false
                $remote = Get-AzureLifecycleJournal $context
                if ($null -eq $remote -or $context.remoteHash -cne (Get-LifecycleFileHash (Join-Path $workspace 'inventory.json'))) { throw 'lifecycle.azure.localJournalStale' }
            }
            $actual = $context.inventory
            if ($actual.iac.commit -cne $inventory.iac.commit -or $actual.releaseSha256 -cne $inventory.releaseSha256 -or $actual.descriptorSha256 -cne $inventory.descriptorSha256 -or
                (Get-SnapshotHash $actual.components) -cne (Get-SnapshotHash $inventory.components)) { throw 'lifecycle.ephemeral.creationContextChanged' }
            $trusted = Invoke-LifecycleCommand git @('rev-parse', 'origin/main') $repository -TimeoutSeconds 30
            if ($trusted.exitCode -ne 0) { throw 'lifecycle.snapshotTrustedCommitUnavailable' }
            $trustedCommit = $trusted.text.Trim()
            $context.snapshot = Read-LifecycleSnapshot $actual (Join-Path $workspace 'snapshot.zip') $repository $trustedCommit
            $context.directory = Join-Path $workspace "snapshots/$($actual.iac.snapshotSha256)"; $context.runtime = Join-Path $workspace 'runtime'
            $stageCommand = $(if ($aws) { 'Invoke-AwsApplicationStage' } else { 'Invoke-AzureApplicationStage' })
            $result = & $stageCommand $context $delivery $release $DeliverySha256 $Stage $repository $trustedCommit $workspace $ReviewSha256 $Confirmation -Confirm:$false
            $status = $result.status; $details = $result.details
        }
    }
}
catch { $status = 'Blocked'; $code = $(if ($_.Exception.Message -cmatch '^lifecycle[.][A-Za-z0-9.]+$') { $_.Exception.Message } else { 'lifecycle.delivery.operationFailed' }) }
finally {
    if ($context -and $context.leaseId) {
        if ($aws) { try { Exit-AwsLifecycleLease $context -Confirm:$false } catch { $status = 'Blocked'; $code = 'lifecycle.aws.leaseReleaseFailed' } }
        else { try { Exit-AzureLifecycleLease $context -Confirm:$false } catch { $status = 'Blocked'; $code = 'lifecycle.azure.leaseReleaseFailed' } }
    }
}
if ($env:GITHUB_STEP_SUMMARY) {
    $store = $(if ($aws) { 'the instance prefix of the S3 state bucket' } else { 'the instance Blob container' })
    $summary = "Delivery: $Stage; environment: $Environment; instance: $InstanceId; status: $status.`nInventory, delivery journal, evidence and reviews remain in $store. applicationVerified=false is not a claim of continued availability.`n"
    if ($details.ContainsKey('reviewSha256')) { $summary += "Review SHA-256: $($details.reviewSha256). Review the private plan or acceptance resource consent in $store before a separate Apply/Acceptance dispatch.`n" }
    if ($details.ContainsKey('journeySucceeded')) { $summary += "Authenticated journey succeeded: $($details.journeySucceeded); cleanup: $($details.cleanupStatus).`n" }
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summary
}
$json = @{ apiVersion = 'hexagon.ec/application-delivery-result/v1'; status = $status; stage = $Stage; applicationVerified = $false; details = $details; code = $code } | ConvertTo-Json -Depth 8
if (-not ($json | Test-Json -SchemaFile (Join-Path $PSScriptRoot '../contracts/schemas/application-delivery-result-v1.schema.json') -ErrorAction SilentlyContinue)) { throw 'lifecycle.delivery.resultInvalid' }
$json
if ($status -ceq 'Blocked') { exit 1 }; if ($status -ceq 'Unverified') { exit 2 }; exit 0
