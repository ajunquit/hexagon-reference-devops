Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($name in @('EnvironmentLifecycle', 'EnvironmentSnapshot', 'AzureEnvironmentStore', 'TerraformAzureLifecycle')) { Import-Module (Join-Path $PSScriptRoot "$name.psm1") }

function Get-AcceptanceBinding([hashtable] $Inventory) {
    return Get-SnapshotHash @{
        product = $Inventory.product; environment = $Inventory.environment; instance = $Inventory.instance
        target = $Inventory.target; iac = $Inventory.iac; releaseSha256 = $Inventory.releaseSha256
        descriptorSha256 = $Inventory.descriptorSha256; components = $Inventory.components; dataPolicy = $Inventory.dataPolicy
        roots = @($Inventory.roots | Sort-Object id | ForEach-Object {
            $binding = @{ id = $_.id; adapter = $_.adapter; dependsOn = $_.dependsOn
                stateKey = $_.stateKey; configurationSha256 = $_.configurationSha256; inputsSha256 = $_.inputsSha256 }
            # AWS roots are scoped by their short prefix (ADR 0025); Azure keeps its resource group.
            if ($_.ContainsKey('namePrefix')) { $binding.namePrefix = $_.namePrefix } else { $binding.resourceGroup = $_.resourceGroup }
            $binding
        })
    }
}

function New-AcceptanceConsent {
    param([hashtable] $Inventory, [string] $DeliverySha256, [string] $DeploymentSha256,
        [long] $CreatedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    Assert-EnvironmentInventory $Inventory
    if ($Inventory.instance.kind -cne 'Ephemeral' -or $Inventory.environment -cnotin @('dev', 'staging') -or $Inventory.dataPolicy -cne 'DeleteEphemeral' -or
        (@($Inventory.roots.id | Sort-Object) -join ',') -cne 'hosting,messaging' -or $DeliverySha256 -cnotmatch '^[0-9a-f]{64}$' -or $DeploymentSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'lifecycle.acceptance.scopeInvalid' }
    foreach ($root in $Inventory.roots) {
        if ($root.status -cne 'Verified' -or $root.lastOperation -cne 'Create' -or $null -ne $root.plan -or @($root.resources | Where-Object current).Count -eq 0) { throw 'lifecycle.acceptance.readyInventoryRequired' }
    }
    return @{
        apiVersion = 'hexagon.ec/acceptance-cleanup-consent/v1'; createdAt = $CreatedAt
        product = $Inventory.product; environment = $Inventory.environment; instanceId = $Inventory.instance.id
        bindingSha256 = Get-AcceptanceBinding $Inventory; deliverySha256 = $DeliverySha256; deploymentSha256 = $DeploymentSha256
        roots = @($Inventory.roots | Sort-Object id | ForEach-Object {
            $approved = @{ id = $_.id; stateLineage = $_.stateLineage; stateSerial = $_.stateSerial
                resources = @($_.resources | Where-Object current | Sort-Object id | ForEach-Object { @{ id = $_.id; type = $_.type; address = $_.address } }) }
            if ($_.ContainsKey('namePrefix')) { $approved.namePrefix = $_.namePrefix } else { $approved.resourceGroup = $_.resourceGroup }
            $approved
        })
    }
}

function Assert-AcceptanceConsent([hashtable] $Inventory, [hashtable] $Consent, [string] $DeliverySha256, [string] $DeploymentSha256, [string] $Confirmation) {
    $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $Consent.createdAt
    if ($age -gt 86400 -or $age -lt -60 -or $Confirmation -cne "TEST AND CLEANUP $($Inventory.product) $($Inventory.environment) $($Inventory.instance.id)") { throw 'lifecycle.acceptance.consentInvalid' }
    $expected = New-AcceptanceConsent $Inventory $DeliverySha256 $DeploymentSha256 $Consent.createdAt
    if ((Get-SnapshotHash $Consent) -cne (Get-SnapshotHash $expected)) { throw 'lifecycle.acceptance.consentStale' }
}

function Assert-AcceptanceDestroyPlan([hashtable] $Inventory, [hashtable] $Root, [hashtable] $Consent, [hashtable] $Plan) {
    if ((Get-AcceptanceBinding $Inventory) -cne $Consent.bindingSha256) { throw 'lifecycle.acceptance.consentStale' }
    $approved = @($Consent.roots | Where-Object id -CEQ $Root.id)
    if ($approved.Count -ne 1 -or $Root.stateLineage -cne $approved[0].stateLineage -or $Root.stateSerial -ne $approved[0].stateSerial) { throw 'lifecycle.acceptance.stateChanged' }
    $owned = @($Root.resources | Where-Object current | Sort-Object id | ForEach-Object { @{ id = $_.id; type = $_.type; address = $_.address } })
    if ((Get-SnapshotHash $owned) -cne (Get-SnapshotHash $approved[0].resources)) { throw 'lifecycle.acceptance.resourcesChanged' }
    Assert-EnvironmentTerraformPlan $Inventory $Root Destroy $Plan
    $observed = @()
    if ($Plan.ContainsKey('resource_changes')) {
        foreach ($change in $Plan.resource_changes) {
            if ($change.mode -ceq 'data') { continue }
            if (-not $change.change.ContainsKey('before') -or $null -eq $change.change.before -or -not $change.change.before.ContainsKey('id')) { throw 'lifecycle.acceptance.deleteUnapproved' }
            # The inventory records AWS resources as aws:<account>:<region>:<type>:<id> (ADR 0025).
            $id = ConvertTo-LifecycleResourceId $Inventory $change.type ([string] $change.change.before.id)
            if (@($owned | Where-Object { $_.id -ieq $id -and $_.address -ceq $change.address -and $_.type -ceq $change.type }).Count -ne 1) { throw 'lifecycle.acceptance.deleteUnapproved' }
            $observed += $id.ToLowerInvariant()
        }
    }
    if ((($observed | Sort-Object) -join ',') -cne ((@($owned.id | ForEach-Object ToLowerInvariant) | Sort-Object) -join ',')) { throw 'lifecycle.acceptance.deleteSetIncomplete' }
}

function Invoke-AcceptanceCleanup {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context, [hashtable] $Consent, [string] $Workspace)
    if (-not $PSCmdlet.ShouldProcess($Context.prefix, 'Retire only the pre-reviewed ephemeral resource set')) { return }
    $inventoryPath = Join-Path $Workspace 'inventory.json'
    Invoke-AzureLifecycleQuiesce $Context -Confirm:$false | Out-Null
    foreach ($id in @(Get-EnvironmentRootOrder $Context.inventory Destroy)) {
        $Context.inventory = Read-EnvironmentInventory $inventoryPath
        $root = @($Context.inventory.roots | Where-Object id -CEQ $id)[0]
        $plan = New-AzureLifecyclePlan $Context $root Destroy -Confirm:$false
        $json = Get-Content -Raw -LiteralPath $plan.jsonPath | ConvertFrom-Json -AsHashtable -Depth 100
        Assert-AcceptanceDestroyPlan $Context.inventory $root $Consent $json
        $hash = Add-EnvironmentRootPlan $inventoryPath $id Destroy $plan.binaryPath $plan.jsonPath (Get-LifecycleFileHash $inventoryPath) -Confirm:$false
        Publish-AzureLifecycleObject $Context "$($Context.prefix)/plans/$hash/$id.tfplan" ([IO.File]::ReadAllBytes($plan.binaryPath)) (Get-LifecycleFileHash $plan.binaryPath) -Confirm:$false
        Publish-AzureLifecycleObject $Context "$($Context.prefix)/plans/$hash/$id.json" ([IO.File]::ReadAllBytes($plan.jsonPath)) (Get-LifecycleFileHash $plan.jsonPath) -Confirm:$false
        Save-AzureLifecycleJournal $Context $inventoryPath | Out-Null
        $Context.inventory = Read-EnvironmentInventory $inventoryPath
        $port = New-AzureLifecyclePort $Context
        $confirmation = "DESTROY $($Context.inventory.product) $($Context.inventory.environment) $($Context.inventory.instance.id)"
        Invoke-EnvironmentRootOperation $inventoryPath $id $plan.binaryPath $plan.jsonPath $hash $confirmation $port -Confirm:$false | Out-Null
    }
    $Context.inventory = Read-EnvironmentInventory $inventoryPath
    if (@($Context.inventory.roots | Where-Object status -CNE 'Destroyed').Count -ne 0) { throw 'lifecycle.acceptance.cleanupIncomplete' }
}

Export-ModuleMember -Function New-AcceptanceConsent, Assert-AcceptanceConsent, Assert-AcceptanceDestroyPlan, Invoke-AcceptanceCleanup
