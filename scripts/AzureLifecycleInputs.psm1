Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'EnvironmentLifecycle.psm1')
Import-Module (Join-Path $PSScriptRoot 'EnvironmentSnapshot.psm1')
Import-Module (Join-Path $PSScriptRoot 'AzureEnvironmentStore.psm1')

function Update-AzureLifecycleInputs {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context, [string] $RootId, [string] $InputDirectory, [string] $Repository,
        [string] $TrustedCommit, [string] $InventoryPath, [string] $Archive, [switch] $AllowUnchanged)
    if (-not $PSCmdlet.ShouldProcess($RootId, 'Update snapshot inputs under lifecycle lease')) { return }
    Assert-AzureLifecycleLease $Context
    $model = $Context.inventory
    $root = @($model.roots | Where-Object id -CEQ $RootId)[0]
    $newArchive = Join-Path $Context.runtime "snapshot-$([guid]::NewGuid().ToString('N')).zip"
    $updated = New-LifecycleSnapshot -Inventory $model -Repository $Repository -TrustedCommit $TrustedCommit -InputDirectory $InputDirectory -Archive $newArchive -Confirm:$false
    foreach ($other in $model.roots) {
        $candidate = @($updated.roots | Where-Object id -CEQ $other.id)[0]
        if ($candidate.configurationSha256 -cne $other.configurationSha256 -or ($other.id -cne $RootId -and $candidate.inputsSha256 -cne $other.inputsSha256)) { throw 'lifecycle.azure.unselectedInputsChanged' }
    }
    $newRoot = @($updated.roots | Where-Object id -CEQ $RootId)[0]
    if ($newRoot.inputsSha256 -ceq $root.inputsSha256) {
        if ($AllowUnchanged) { return }
        throw 'lifecycle.azure.inputsUnchanged'
    }
    $verified = Read-LifecycleSnapshot $updated $newArchive $Repository $TrustedCommit
    $directory = Join-Path (Split-Path -Parent $Archive) "snapshots/$($updated.iac.snapshotSha256)"
    Expand-LifecycleSnapshot $verified $directory -Confirm:$false
    Publish-AzureLifecycleObject $Context "$($Context.prefix)/snapshots/$($updated.iac.snapshotSha256).zip" ([IO.File]::ReadAllBytes($newArchive)) $updated.iac.snapshotSha256
    Set-EnvironmentRootInputs -InventoryPath $InventoryPath -RootId $RootId -InputsSha256 $newRoot.inputsSha256 -SnapshotSha256 $updated.iac.snapshotSha256 -ExpectedInventorySha256 (Get-LifecycleFileHash $InventoryPath) -Confirm:$false
    [IO.File]::Move($newArchive, $Archive, $true)
    $Context.inventory = Read-EnvironmentInventory $InventoryPath
    $Context.snapshot = $verified; $Context.directory = $directory
    Save-AzureLifecycleJournal $Context $InventoryPath | Out-Null
}

Export-ModuleMember -Function Update-AzureLifecycleInputs
