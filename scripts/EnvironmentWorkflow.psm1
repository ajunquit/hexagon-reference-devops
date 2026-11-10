Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'EphemeralEnvironment.psm1')
Import-Module (Join-Path $PSScriptRoot 'PlatformBootstrap.psm1')

function Invoke-WorkflowPort([scriptblock] $Port, [string] $Action) {
    $result = & $Port $Action
    if ($null -eq $result -or $result -isnot [Collections.IDictionary] -or $null -eq $result['status']) { throw 'lifecycle.ephemeral.stageResponseInvalid' }
    if ($result.status -cin @('Blocked', 'Unverified')) { throw 'lifecycle.ephemeral.stageBlocked' }
    return $result
}

function Invoke-EphemeralStage {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Definition, [ValidateSet('Create', 'Destroy')][string] $Operation,
        [ValidateSet('Prepare', 'Apply', 'Sync', 'Quiesce')][string] $Mode, [string] $RootId,
        [string] $ReviewSha256, [string] $Confirmation, [Parameter(Mandatory)][scriptblock] $Port)
    $inventory = $Definition.inventory
    Assert-EphemeralSelection $Definition $inventory.environment $inventory.instance.id $Operation
    if ($RootId -cnotin @($inventory.roots.id)) { throw 'lifecycle.rootUnknown' }
    if ($Mode -ceq 'Quiesce' -and $Operation -cne 'Destroy') { throw 'lifecycle.ephemeral.operationMismatch' }
    if ($Mode -ceq 'Apply') {
        if ($ReviewSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'lifecycle.reviewRequired' }
        if ($Confirmation -cne "$($Operation.ToUpperInvariant()) $($inventory.product) $($inventory.environment) $($inventory.instance.id)") { throw 'lifecycle.confirmationMismatch' }
    }
    if ($Mode -ceq 'Quiesce' -and $Confirmation -cne "QUIESCE $($inventory.product) $($inventory.environment) $($inventory.instance.id)") { throw 'lifecycle.confirmationMismatch' }
    if (-not $PSCmdlet.ShouldProcess("$($inventory.product)/$($inventory.environment)/$($inventory.instance.id)", "$Mode $Operation $RootId stage")) { return @{ status = 'Unverified'; applicationVerified = $false } }
    $probe = Invoke-WorkflowPort $Port 'Probe'
    if ($null -eq $probe.inventory) {
        if ($Operation -cne 'Create' -or $Mode -cne 'Prepare' -or $RootId -cne 'hosting') { throw 'lifecycle.ephemeral.journalMissing' }
        Invoke-WorkflowPort $Port 'ValidateSources' | Out-Null
        Invoke-WorkflowPort $Port 'Build' | Out-Null
        Invoke-WorkflowPort $Port 'Initialize' | Out-Null
    }
    else {
        $remote = $probe.inventory
        foreach ($field in @('product', 'environment')) { if ($remote[$field] -cne $inventory[$field]) { throw 'lifecycle.selectionMismatch' } }
        if ((ConvertTo-PlatformBootstrapJson $remote.target) -cne (ConvertTo-PlatformBootstrapJson $inventory.target) -or
            (ConvertTo-PlatformBootstrapJson $remote.instance) -cne (ConvertTo-PlatformBootstrapJson $inventory.instance) -or
            (@($remote.roots.id | Sort-Object) -join ',') -cne (@($inventory.roots.id | Sort-Object) -join ',')) { throw 'lifecycle.selectionMismatch' }
        if ($Operation -ceq 'Create') {
            if ($remote.iac.commit -cne $inventory.iac.commit -or $remote.iac.repository -cne $inventory.iac.repository -or $remote.descriptorSha256 -cne $inventory.descriptorSha256 -or $remote.releaseSha256 -cne $inventory.releaseSha256 -or
                (ConvertTo-PlatformBootstrapJson $remote.components) -cne (ConvertTo-PlatformBootstrapJson $inventory.components)) { throw 'lifecycle.ephemeral.creationContextChanged' }
            if (@($remote.roots | Where-Object status -CNE 'Destroyed').Count -eq 0) { throw 'lifecycle.ephemeral.instanceRetired' }
        }
        Invoke-WorkflowPort $Port 'Restore' | Out-Null
        $root = @($remote.roots | Where-Object id -CEQ $RootId)[0]
        if ($Mode -ceq 'Prepare' -and $root.status -cin @('Applying', 'Destroying')) { throw 'lifecycle.reconciliationRequired' }
        if ($Mode -ceq 'Prepare' -and $null -ne $root.lastOperation) { Invoke-WorkflowPort $Port 'Sync' | Out-Null }
    }
    if ($Mode -ceq 'Prepare' -and $Operation -ceq 'Create' -and $RootId -ceq 'messaging') { Invoke-WorkflowPort $Port 'BindMessaging' | Out-Null }
    return Invoke-WorkflowPort $Port $Mode
}

Export-ModuleMember -Function Invoke-EphemeralStage
