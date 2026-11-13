<#
.SYNOPSIS
    Builds a trusted snapshot or coordinates one reviewed AWS lifecycle stage with S3 custody (ADR 0025).
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][ValidateSet('Build', 'Initialize', 'Prepare', 'Apply', 'Sync', 'Restore', 'UpdateInputs', 'BindMessaging', 'Quiesce')][string] $Mode,
    [Parameter(Mandatory)][string] $Inventory,
    [Parameter(Mandatory)][ValidateSet('dev', 'staging', 'prod')][string] $Environment,
    [Parameter(Mandatory)][string] $InstanceId,
    [Parameter(Mandatory)][string] $Workspace,
    [ValidateSet('hosting', 'messaging')][string] $RootId = 'hosting',
    [ValidateSet('Create', 'Destroy')][string] $Operation = 'Create',
    [string] $InputDirectory,
    [string] $ReviewSha256,
    [string] $Confirmation
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'EnvironmentLifecycle.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'EnvironmentSnapshot.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AwsEnvironmentStore.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'TerraformAwsLifecycle.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'LifecycleNative.psm1')
Import-Module (Join-Path $PSScriptRoot 'AwsLifecycleInputs.psm1')
Import-Module (Join-Path $PSScriptRoot 'PlatformBootstrap.psm1')
$context = $null; $status = 'Blocked'; $details = @{}; $code = $null

function Assert-WorkspacePath([string] $Path) {
    $repository = Split-Path -Parent $PSScriptRoot
    $prefix = Join-Path $repository 'artifacts'
    $comparison = $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal })
    if (-not $Path.StartsWith($prefix + [IO.Path]::DirectorySeparatorChar, $comparison)) { throw 'lifecycle.aws.workspaceOutsideArtifacts' }
    $ancestor = $Path
    while ($ancestor.Length -ge $prefix.Length) {
        if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'lifecycle.aws.workspaceLink' }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
}

function New-PrivateWorkspace([string] $Path) {
    if (Test-Path -LiteralPath $Path) { throw 'lifecycle.aws.workspaceExists' }
    [IO.Directory]::CreateDirectory($Path) | Out-Null
    if ($IsWindows) {
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($user, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule); Set-Acl -LiteralPath $Path -AclObject $acl
    }
    else { [IO.File]::SetUnixFileMode($Path, [IO.UnixFileMode] 'UserRead,UserWrite,UserExecute') }
}

function Update-CurrentSnapshotInputs([string] $Directory, [bool] $AllowUnchanged = $false) {
    Update-AwsLifecycleInputs -Context $context -RootId $RootId -InputDirectory $Directory -Repository $repository -TrustedCommit $trustedCommit -InventoryPath $localInventory -Archive $archive -AllowUnchanged:$AllowUnchanged -Confirm:$false
}

try {
    $repository = Split-Path -Parent $PSScriptRoot
    $model = Read-EnvironmentInventory $Inventory
    $product = (Get-Content -Raw -LiteralPath (Join-Path $repository '.config/product.json') | ConvertFrom-Json).product
    if ($model.product -cne $product -or $model.environment -cne $Environment -or $model.instance.id -cne $InstanceId) { throw 'lifecycle.selectionMismatch' }
    $workspacePath = [IO.Path]::GetFullPath($Workspace, (Get-Location).ProviderPath)
    Assert-WorkspacePath $workspacePath
    if ($WhatIfPreference) { $status = 'Unverified' }
    elseif ($PSCmdlet.ShouldProcess("$product/$Environment/$InstanceId", "$Mode AWS lifecycle stage")) {
        $trusted = Invoke-LifecycleCommand git @('rev-parse', 'origin/main') $repository -TimeoutSeconds 30
        if ($trusted.exitCode -ne 0) { throw 'lifecycle.snapshotTrustedCommitUnavailable' }
        $trustedCommit = $trusted.text.Trim()
        $localInventory = Join-Path $workspacePath 'inventory.json'; $archive = Join-Path $workspacePath 'snapshot.zip'
        if ($Mode -ceq 'Build') {
            Assert-EnvironmentInitialInventory $model
            New-PrivateWorkspace $workspacePath
            $materialized = New-LifecycleSnapshot -Inventory $model -Repository $repository -TrustedCommit $trustedCommit -InputDirectory ([IO.Path]::GetFullPath($InputDirectory, (Get-Location).ProviderPath)) -Archive $archive -Confirm:$false
            New-EnvironmentInventory $materialized $localInventory -Confirm:$false | Out-Null
            $snapshot = Read-LifecycleSnapshot $materialized $archive $repository $trustedCommit
            Expand-LifecycleSnapshot $snapshot (Join-Path $workspacePath "snapshots/$($materialized.iac.snapshotSha256)") -Confirm:$false
            [IO.Directory]::CreateDirectory((Join-Path $workspacePath 'runtime')) | Out-Null
            $details = @{ inventoryPath = $localInventory; snapshotSha256 = $materialized.iac.snapshotSha256 }; $status = 'Built'
        }
        else {
            if ($Mode -cne 'Restore' -and ([IO.Path]::GetFullPath($Inventory, (Get-Location).ProviderPath) -cne $localInventory)) { throw 'lifecycle.aws.inventoryPathMismatch' }
            if (-not $model.target.ContainsKey('accountId')) { throw 'lifecycle.aws.targetRequired' }
            Assert-LifecycleCliEnvironment
            $caller = Invoke-LifecycleCommand aws @('sts', 'get-caller-identity', '--region', $model.target.region, '--output', 'json') -TimeoutSeconds 45
            if ($caller.exitCode -ne 0) { throw 'lifecycle.aws.accountUnavailable' }
            $identity = $caller.text | ConvertFrom-Json -AsHashtable
            $context = New-AwsLifecycleContext $model $identity.Arn $identity.Account
            if ($Mode -cin @('Apply', 'Quiesce')) { Assert-AwsLifecycleRuntime $context }
            Enter-AwsLifecycleLease $context -Confirm:$false
            $remote = Get-AwsLifecycleJournal $context
            if ($Mode -ceq 'Restore') {
                if ($null -eq $remote) { throw 'lifecycle.aws.journalMissing' }
                $context.inventory = $remote.inventory; $model = $remote.inventory
                $bytes = Read-AwsLifecycleObject $context "snapshots/$($model.iac.snapshotSha256).zip" $model.iac.snapshotSha256
                New-PrivateWorkspace $workspacePath
                [IO.File]::WriteAllBytes($archive, $bytes); [IO.File]::WriteAllBytes($localInventory, $remote.bytes)
                $snapshot = Read-LifecycleSnapshot $model $archive $repository $trustedCommit
                Expand-LifecycleSnapshot $snapshot (Join-Path $workspacePath "snapshots/$($model.iac.snapshotSha256)") -Confirm:$false
                [IO.Directory]::CreateDirectory((Join-Path $workspacePath 'runtime')) | Out-Null
                $status = 'Restored'; $details = @{ inventoryPath = $localInventory }
            }
            else {
                $snapshot = Read-LifecycleSnapshot $model $archive $repository $trustedCommit
                if ($null -ne $remote -and $context.remoteHash -cne (Get-LifecycleFileHash $localInventory)) { throw 'lifecycle.aws.localJournalStale' }
                if ($Mode -ceq 'Initialize') {
                    Assert-EnvironmentInitialInventory $model
                    if ($null -eq $remote) {
                        Publish-AwsLifecycleObject $context "snapshots/$($model.iac.snapshotSha256).zip" ([IO.File]::ReadAllBytes($archive)) $model.iac.snapshotSha256 -Confirm:$false
                        Save-AwsLifecycleJournal $context $localInventory -Confirm:$false | Out-Null
                    }
                    else { Read-AwsLifecycleObject $context "snapshots/$($model.iac.snapshotSha256).zip" $model.iac.snapshotSha256 | Out-Null }
                    $status = 'Initialized'
                }
                else {
                    if ($null -eq $remote) { throw 'lifecycle.aws.journalMissing' }
                    $context.snapshot = $snapshot; $context.directory = Join-Path $workspacePath "snapshots/$($model.iac.snapshotSha256)"; $context.runtime = Join-Path $workspacePath 'runtime'
                    $root = @($model.roots | Where-Object id -CEQ $RootId)
                    if ($root.Count -ne 1) { throw 'lifecycle.rootUnknown' }; $root = $root[0]
                    $port = New-AwsLifecyclePort $context
                    switch ($Mode) {
                        'Prepare' {
                            $plan = New-AwsLifecyclePlan $context $root $Operation -Confirm:$false
                            $hash = Add-EnvironmentRootPlan -InventoryPath $localInventory -RootId $RootId -Operation $Operation -BinaryPath $plan.binaryPath -JsonPath $plan.jsonPath -ExpectedInventorySha256 (Get-LifecycleFileHash $localInventory) -Confirm:$false
                            Publish-AwsLifecycleObject $context "plans/$hash/$RootId.tfplan" ([IO.File]::ReadAllBytes($plan.binaryPath)) (Get-LifecycleFileHash $plan.binaryPath) -Confirm:$false
                            Publish-AwsLifecycleObject $context "plans/$hash/$RootId.json" ([IO.File]::ReadAllBytes($plan.jsonPath)) (Get-LifecycleFileHash $plan.jsonPath) -Confirm:$false
                            Save-AwsLifecycleJournal $context $localInventory -Confirm:$false | Out-Null
                            $status = 'Prepared'; $details = @{ reviewSha256 = $hash }
                        }
                        'UpdateInputs' {
                            Update-CurrentSnapshotInputs ([IO.Path]::GetFullPath($InputDirectory, (Get-Location).ProviderPath))
                            $status = 'InputsUpdated'
                        }
                        'BindMessaging' {
                            # AWS messaging uses the task roles of hosting by name: prove the binding, keep the reviewed inputs.
                            if ($RootId -cne 'messaging' -or $root.lastOperation -ceq 'Destroy') { throw 'lifecycle.aws.bindingRootInvalid' }
                            $inputValue = [Text.Encoding]::UTF8.GetString($snapshot.files['inputs/messaging.tfvars.json']) | ConvertFrom-Json -AsHashtable -Depth 32
                            Assert-AwsMessagingBindings $context $inputValue
                            $status = 'InputsBound'
                        }
                        'Quiesce' {
                            if ($Confirmation -cne "QUIESCE $product $Environment $InstanceId") { throw 'lifecycle.confirmationMismatch' }
                            $before = Get-LifecycleFileHash $localInventory
                            Clear-EnvironmentPlans $localInventory $before -Confirm:$false
                            if ((Get-LifecycleFileHash $localInventory) -cne $before) { Save-AwsLifecycleJournal $context $localInventory -Confirm:$false | Out-Null }
                            $context.inventory = Read-EnvironmentInventory $localInventory
                            Invoke-AwsLifecycleQuiesce $context -Confirm:$false | Out-Null
                            $status = 'Quiesced'
                        }
                        'Apply' {
                            if ($null -eq $root.plan -or $root.plan.reviewSha256 -cne $ReviewSha256) { throw 'lifecycle.reviewRequired' }
                            $binary = Join-Path $context.runtime "$RootId.tfplan"
                            $binaryBytes = Read-AwsLifecycleObject $context "plans/$ReviewSha256/$RootId.tfplan" $root.plan.binarySha256
                            $jsonBytes = Read-AwsLifecycleObject $context "plans/$ReviewSha256/$RootId.json" $root.plan.jsonSha256
                            [IO.File]::WriteAllBytes($binary, $binaryBytes); [IO.File]::WriteAllBytes("$binary.json", $jsonBytes)
                            $result = Invoke-EnvironmentRootOperation -InventoryPath $localInventory -RootId $RootId -BinaryPath $binary -JsonPath "$binary.json" -ReviewSha256 $ReviewSha256 -Confirmation $Confirmation -Port $port -Confirm:$false
                            $status = $result.status
                        }
                        'Sync' { $result = Sync-EnvironmentRoot -InventoryPath $localInventory -RootId $RootId -Port $port -Confirm:$false; $status = $result.status }
                    }
                }
            }
        }
    }
}
catch {
    $code = $_.Exception.Message
    if ($code -cnotmatch '^lifecycle[.][A-Za-z0-9.]+$') { $code = 'lifecycle.aws.operationFailed' }
    $status = 'Blocked'
}
finally {
    if ($null -ne $context -and $context.leaseId) {
        try { Exit-AwsLifecycleLease $context -Confirm:$false } catch { $status = 'Blocked'; $code = 'lifecycle.aws.leaseReleaseFailed' }
    }
}
$json = @{ apiVersion = 'hexagon.ec/aws-environment-result/v1'; status = $status; mode = $Mode; applicationVerified = $false; details = $details; code = $code } | ConvertTo-Json -Depth 8
if (-not ($json | Test-Json -SchemaFile (Join-Path $repository 'contracts/schemas/aws-environment-result-v1.schema.json') -ErrorAction SilentlyContinue)) { throw 'lifecycle.aws.resultInvalid' }
$json
if ($status -cin @('Blocked', 'Failed')) { exit 1 }
if ($status -ceq 'Unverified') { exit 2 }
exit 0
