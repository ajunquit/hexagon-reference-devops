<#
.SYNOPSIS
    Builds a trusted snapshot or coordinates one reviewed Azure lifecycle stage with durable storage.
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
Import-Module (Join-Path $PSScriptRoot 'AzureEnvironmentStore.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'TerraformAzureLifecycle.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'LifecycleNative.psm1')
Import-Module (Join-Path $PSScriptRoot 'AzureLifecycleInputs.psm1')
Import-Module (Join-Path $PSScriptRoot 'PlatformBootstrap.psm1')
$context = $null; $status = 'Blocked'; $details = @{}; $code = $null

function Assert-WorkspacePath([string] $Path) {
    $repository = Split-Path -Parent $PSScriptRoot
    $prefix = Join-Path $repository 'artifacts'
    $comparison = $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal })
    if (-not $Path.StartsWith($prefix + [IO.Path]::DirectorySeparatorChar, $comparison)) { throw 'lifecycle.azure.workspaceOutsideArtifacts' }
    $ancestor = $Path
    while ($ancestor.Length -ge $prefix.Length) {
        if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'lifecycle.azure.workspaceLink' }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
}

function New-PrivateWorkspace([string] $Path) {
    if (Test-Path -LiteralPath $Path) { throw 'lifecycle.azure.workspaceExists' }
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
    Update-AzureLifecycleInputs -Context $context -RootId $RootId -InputDirectory $Directory -Repository $repository -TrustedCommit $trustedCommit -InventoryPath $localInventory -Archive $archive -AllowUnchanged:$AllowUnchanged -Confirm:$false
}

try {
    $repository = Split-Path -Parent $PSScriptRoot
    $model = Read-EnvironmentInventory $Inventory
    $product = (Get-Content -Raw -LiteralPath (Join-Path $repository '.config/product.json') | ConvertFrom-Json).product
    if ($model.product -cne $product -or $model.environment -cne $Environment -or $model.instance.id -cne $InstanceId) { throw 'lifecycle.selectionMismatch' }
    $workspacePath = [IO.Path]::GetFullPath($Workspace, (Get-Location).ProviderPath)
    Assert-WorkspacePath $workspacePath
    if ($WhatIfPreference) { $status = 'Unverified' }
    elseif ($PSCmdlet.ShouldProcess("$product/$Environment/$InstanceId", "$Mode Azure lifecycle stage")) {
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
            if ($Mode -cne 'Restore' -and ([IO.Path]::GetFullPath($Inventory, (Get-Location).ProviderPath) -cne $localInventory)) { throw 'lifecycle.azure.inventoryPathMismatch' }
            $context = New-AzureLifecycleContext $model
            if ($Mode -cin @('Apply', 'Quiesce')) { Assert-AzureLifecycleRuntime $context }
            foreach ($root in $model.roots) { Get-AzureLifecycleScope $context $root | Out-Null }
            Enter-AzureLifecycleLease $context
            $remote = Get-AzureLifecycleJournal $context
            if ($Mode -ceq 'Restore') {
                if ($null -eq $remote) { throw 'lifecycle.azure.journalMissing' }
                $context.inventory = $remote.inventory; $model = $remote.inventory
                $bytes = Read-AzureLifecycleObject $context "$($context.prefix)/snapshots/$($model.iac.snapshotSha256).zip" $model.iac.snapshotSha256
                New-PrivateWorkspace $workspacePath
                [IO.File]::WriteAllBytes($archive, $bytes); [IO.File]::WriteAllBytes($localInventory, $remote.bytes)
                $snapshot = Read-LifecycleSnapshot $model $archive $repository $trustedCommit
                Expand-LifecycleSnapshot $snapshot (Join-Path $workspacePath "snapshots/$($model.iac.snapshotSha256)") -Confirm:$false
                [IO.Directory]::CreateDirectory((Join-Path $workspacePath 'runtime')) | Out-Null
                $status = 'Restored'; $details = @{ inventoryPath = $localInventory }
            }
            else {
                $snapshot = Read-LifecycleSnapshot $model $archive $repository $trustedCommit
                if ($null -ne $remote -and $context.remoteHash -cne (Get-LifecycleFileHash $localInventory)) { throw 'lifecycle.azure.localJournalStale' }
                if ($Mode -ceq 'Initialize') {
                    Assert-EnvironmentInitialInventory $model
                    if ($null -eq $remote) {
                        Publish-AzureLifecycleObject $context "$($context.prefix)/snapshots/$($model.iac.snapshotSha256).zip" ([IO.File]::ReadAllBytes($archive)) $model.iac.snapshotSha256
                        Save-AzureLifecycleJournal $context $localInventory | Out-Null
                    }
                    else { Read-AzureLifecycleObject $context "$($context.prefix)/snapshots/$($model.iac.snapshotSha256).zip" $model.iac.snapshotSha256 | Out-Null }
                    $status = 'Initialized'
                }
                else {
                    if ($null -eq $remote) { throw 'lifecycle.azure.journalMissing' }
                    $context.snapshot = $snapshot; $context.directory = Join-Path $workspacePath "snapshots/$($model.iac.snapshotSha256)"; $context.runtime = Join-Path $workspacePath 'runtime'
                    $root = @($model.roots | Where-Object id -CEQ $RootId)
                    if ($root.Count -ne 1) { throw 'lifecycle.rootUnknown' }; $root = $root[0]
                    $port = New-AzureLifecyclePort $context
                    switch ($Mode) {
                        'Prepare' {
                            $plan = New-AzureLifecyclePlan $context $root $Operation -Confirm:$false
                            $hash = Add-EnvironmentRootPlan -InventoryPath $localInventory -RootId $RootId -Operation $Operation -BinaryPath $plan.binaryPath -JsonPath $plan.jsonPath -ExpectedInventorySha256 (Get-LifecycleFileHash $localInventory) -Confirm:$false
                            Publish-AzureLifecycleObject $context "$($context.prefix)/plans/$hash/$RootId.tfplan" ([IO.File]::ReadAllBytes($plan.binaryPath)) (Get-LifecycleFileHash $plan.binaryPath)
                            Publish-AzureLifecycleObject $context "$($context.prefix)/plans/$hash/$RootId.json" ([IO.File]::ReadAllBytes($plan.jsonPath)) (Get-LifecycleFileHash $plan.jsonPath)
                            Save-AzureLifecycleJournal $context $localInventory | Out-Null
                            $status = 'Prepared'; $details = @{ reviewSha256 = $hash }
                        }
                        'UpdateInputs' {
                            Update-CurrentSnapshotInputs ([IO.Path]::GetFullPath($InputDirectory, (Get-Location).ProviderPath))
                            $status = 'InputsUpdated'
                        }
                        'BindMessaging' {
                            if ($RootId -cne 'messaging' -or $root.lastOperation -ceq 'Destroy') { throw 'lifecycle.azure.bindingRootInvalid' }
                            $principals = Get-AzureLifecycleWorkloadPrincipals $context
                            $directory = Join-Path $context.runtime "binding-$([guid]::NewGuid().ToString('N'))"
                            [IO.Directory]::CreateDirectory($directory) | Out-Null
                            foreach ($item in $model.roots) {
                                $bytes = $snapshot.files["inputs/$($item.id).tfvars.json"]
                                if ($item.id -ceq 'messaging') {
                                    $inputValue = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -AsHashtable -Depth 32
                                    $inputValue = ConvertTo-AzureMessagingPrincipalInput $inputValue $principals
                                    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson $inputValue) + "`n")
                                }
                                [IO.File]::WriteAllBytes((Join-Path $directory "$($item.id).tfvars.json"), $bytes)
                            }
                            Update-CurrentSnapshotInputs $directory $true
                            $status = 'InputsBound'
                        }
                        'Quiesce' {
                            if ($Confirmation -cne "QUIESCE $product $Environment $InstanceId") { throw 'lifecycle.confirmationMismatch' }
                            $before = Get-LifecycleFileHash $localInventory
                            Clear-EnvironmentPlans $localInventory $before -Confirm:$false
                            if ((Get-LifecycleFileHash $localInventory) -cne $before) { Save-AzureLifecycleJournal $context $localInventory | Out-Null }
                            $context.inventory = Read-EnvironmentInventory $localInventory
                            Invoke-AzureLifecycleQuiesce $context -Confirm:$false | Out-Null
                            $status = 'Quiesced'
                        }
                        'Apply' {
                            if ($null -eq $root.plan -or $root.plan.reviewSha256 -cne $ReviewSha256) { throw 'lifecycle.reviewRequired' }
                            $binary = Join-Path $context.runtime "$RootId.tfplan"
                            $binaryBytes = Read-AzureLifecycleObject $context "$($context.prefix)/plans/$ReviewSha256/$RootId.tfplan" $root.plan.binarySha256
                            $jsonBytes = Read-AzureLifecycleObject $context "$($context.prefix)/plans/$ReviewSha256/$RootId.json" $root.plan.jsonSha256
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
    if ($code -cnotmatch '^lifecycle[.][A-Za-z0-9.]+$') { $code = 'lifecycle.azure.operationFailed' }
    $status = 'Blocked'
}
finally {
    if ($null -ne $context -and $context.leaseId) {
        try { Exit-AzureLifecycleLease $context } catch { $status = 'Blocked'; $code = 'lifecycle.azure.leaseReleaseFailed' }
    }
}
$json = @{ apiVersion = 'hexagon.ec/azure-environment-result/v1'; status = $status; mode = $Mode; applicationVerified = $false; details = $details; code = $code } | ConvertTo-Json -Depth 8
if (-not ($json | Test-Json -SchemaFile (Join-Path $repository 'contracts/schemas/azure-environment-result-v1.schema.json') -ErrorAction SilentlyContinue)) { throw 'lifecycle.azure.resultInvalid' }
$json
if ($status -cin @('Blocked', 'Failed')) { exit 1 }
if ($status -ceq 'Unverified') { exit 2 }
exit 0
