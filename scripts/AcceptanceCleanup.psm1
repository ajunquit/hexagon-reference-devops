Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($name in @('EnvironmentLifecycle', 'EnvironmentSnapshot')) { Import-Module (Join-Path $PSScriptRoot "$name.psm1") }

function Get-AcceptanceBinding([hashtable] $Inventory) {
    $rules = Get-EnvironmentRules $Inventory
    return Get-SnapshotHash @{
        product = $Inventory.product; environment = $Inventory.environment; instance = $Inventory.instance
        target = $Inventory.target; iac = $Inventory.iac; releaseSha256 = $Inventory.releaseSha256
        descriptorSha256 = $Inventory.descriptorSha256; components = $Inventory.components; dataPolicy = $Inventory.dataPolicy
        roots = @($Inventory.roots | Sort-Object id | ForEach-Object {
            $binding = @{ id = $_.id; adapter = $_.adapter; dependsOn = $_.dependsOn
                stateKey = $_.stateKey; configurationSha256 = $_.configurationSha256; inputsSha256 = $_.inputsSha256 }
            # Each cloud names the scope of its roots (its environment rules).
            $scope = Invoke-EnvironmentRules $rules Get-EnvironmentRulesRootBinding @(, $_)
            foreach ($key in $scope.Keys) { $binding[$key] = $scope[$key] }
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
            # The inventory records the identifier that the rules of its cloud qualify.
            $id = ConvertTo-LifecycleResourceId $Inventory $change.type ([string] $change.change.before.id)
            if (@($owned | Where-Object { $_.id -ieq $id -and $_.address -ceq $change.address -and $_.type -ceq $change.type }).Count -ne 1) { throw 'lifecycle.acceptance.deleteUnapproved' }
            $observed += $id.ToLowerInvariant()
        }
    }
    if ((($observed | Sort-Object) -join ',') -cne ((@($owned.id | ForEach-Object ToLowerInvariant) | Sort-Object) -join ',')) { throw 'lifecycle.acceptance.deleteSetIncomplete' }
}

Export-ModuleMember -Function New-AcceptanceConsent, Assert-AcceptanceConsent, Assert-AcceptanceDestroyPlan
