<#
.SYNOPSIS
    Exercises consent admission, delete-only policy and cleanup after failed journeys; no cloud calls.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
foreach ($name in @('AcceptanceCleanup', 'AcceptanceRun', 'AzureAcceptance', 'PlatformBootstrap')) { Import-Module (Join-Path $repository "scripts/$name.psm1") -Force }
$script:assertions = 0
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message }; $script:assertions++ }
function Assert-Rejected([scriptblock] $Action, [string] $Code) {
    try { & $Action | Out-Null } catch { Assert-True ($_.Exception.Message -like "*$Code*") "Unexpected rejection: $($_.Exception.Message)"; return }
    throw "Expected rejection: $Code"
}
function Copy-Value($Value) { return (ConvertTo-PlatformBootstrapJson $Value) | ConvertFrom-Json -AsHashtable -Depth 30 }
$inventory = Get-Content -Raw (Join-Path $repository 'examples/environment-inventory.json') | ConvertFrom-Json -AsHashtable
foreach ($root in $inventory.roots) {
    $root.status = 'Verified'; $root.lastOperation = 'Create'; $root.stateLineage = '44444444-4444-4444-4444-444444444444'; $root.stateSerial = 3
    $type = $(if ($root.id -ceq 'hosting') { 'azurerm_static_web_app' } else { 'azurerm_servicebus_namespace' })
    $provider = $(if ($root.id -ceq 'hosting') { 'Microsoft.Web/staticSites' } else { 'Microsoft.ServiceBus/namespaces' })
    $root.resources = @(@{ address = "module.$($root.id).$type.this"; id = "/subscriptions/$($inventory.target.subscriptionId)/resourceGroups/$($root.resourceGroup)/providers/$provider/fixture"; type = $type; current = $true; presence = 'Present' })
}
$consent = New-AcceptanceConsent $inventory ('b' * 64) ('c' * 64)
$confirmation = "TEST AND CLEANUP $($inventory.product) dev $($inventory.instance.id)"
Assert-AcceptanceConsent $inventory $consent ('b' * 64) ('c' * 64) $confirmation
$script:assertions++
Assert-Rejected { Assert-AcceptanceConsent $inventory $consent ('b' * 64) ('c' * 64) 'CREATE anything' } 'consentInvalid'
$changed = Copy-Value $consent; $changed.createdAt -= 90000
Assert-Rejected { Assert-AcceptanceConsent $inventory $changed ('b' * 64) ('c' * 64) $confirmation } 'consentInvalid'
$changed = Copy-Value $inventory; $changed.roots[0].stateSerial++
Assert-Rejected { Assert-AcceptanceConsent $changed $consent ('b' * 64) ('c' * 64) $confirmation } 'consentStale'
Assert-Rejected { Assert-AcceptanceConsent $inventory $consent ('d' * 64) ('c' * 64) $confirmation } 'consentStale'
$changed = Copy-Value $inventory; $changed.dataPolicy = 'BackupRequired'
Assert-Rejected { New-AcceptanceConsent $changed ('b' * 64) ('c' * 64) } 'scopeInvalid'
$changed = Copy-Value $inventory; $changed.roots[0].status = 'Failed'
Assert-Rejected { New-AcceptanceConsent $changed ('b' * 64) ('c' * 64) } 'readyInventoryRequired'
$root = $inventory.roots[1]; $resource = $root.resources[0]
$plan = @{ format_version = '1.2'; errored = $false; complete = $true; resource_changes = @(@{ mode = 'managed'; address = $resource.address; type = $resource.type; change = @{ actions = @('delete'); before = @{ id = $resource.id }; after = $null } }) }
Assert-AcceptanceDestroyPlan $inventory $root $consent $plan
$script:assertions++
$bad = Copy-Value $plan; $bad.resource_changes[0].change.actions = @('delete', 'create')
Assert-Rejected { Assert-AcceptanceDestroyPlan $inventory $root $consent $bad } 'planOperationMismatch'
$bad = Copy-Value $plan; $bad.resource_changes[0].change.before.id += '-foreign'
Assert-Rejected { Assert-AcceptanceDestroyPlan $inventory $root $consent $bad } 'planResourceUnrecorded'
$bad = Copy-Value $plan; $bad.resource_changes = @()
Assert-Rejected { Assert-AcceptanceDestroyPlan $inventory $root $consent $bad } 'deleteSetIncomplete'
$changed = Copy-Value $inventory; $changed.roots[1].inputsSha256 = 'f' * 64
Assert-Rejected { Assert-AcceptanceDestroyPlan $changed $changed.roots[1] $consent $plan } 'consentStale'
$fixture = @{ instanceId = $inventory.instance.id; subjectId = '55555555-5555-4555-8555-555555555555'; tenant = "e2e-$($inventory.instance.id)-a"; otherTenant = "e2e-$($inventory.instance.id)-b" }
Get-AcceptanceFixture $inventory @{ acceptance_fixture = $fixture } | Out-Null
$bad = Copy-Value $fixture; $bad.tenant = 'existing-tenant'
Assert-Rejected { Get-AcceptanceFixture $inventory @{ acceptance_fixture = $bad } } 'fixtureInvalid'
Assert-Rejected { Get-AcceptanceFixture $inventory @{} } 'fixtureRequired'

function Reset-Run {
    $script:calls = [Collections.Generic.List[string]]::new(); $script:evidence = [Collections.Generic.List[object]]::new()
    $script:journal = @{ deliverySha256 = 'b' * 64 }
    $script:context = @{ inventory = $inventory; prefix = 'fixture' }
}
$seed = { $script:calls.Add('Seed') }
$persist = { $script:calls.Add("Journal:$($script:journal.acceptance.status)") }
$save = { param($context, $value) $script:evidence.Add((Copy-Value $value)); $script:calls.Add('Evidence'); return 'e' * 64 }
$browser = { param($context, $configuration) $script:calls.Add('Browser'); return @{ status = 'Succeeded'; pkce = $true; authenticatedCreate = $true; workerReaction = $true; tenantIsolation = $true } }
$cleanup = { param($context, $consent, $workspace) $script:calls.Add('Cleanup') }
Reset-Run
$result = Invoke-AcceptanceRun $context $journal $consent ('a' * 64) @{} 'unused' $seed $persist -Browser $browser -Cleanup $cleanup -PersistEvidence $save -Confirm:$false
Assert-True ($result.journeySucceeded -and $result.cleanupStatus -ceq 'Destroyed') 'Acceptance and cleanup must complete separately.'
Assert-True ($calls.IndexOf('Evidence') -lt $calls.IndexOf('Cleanup') -and $calls[0] -ceq 'Journal:Testing') 'Intent and result must be durable before destructive work.'
Assert-Rejected { Invoke-AcceptanceRun $context $journal $consent ('a' * 64) @{} 'unused' $seed $persist -Browser $browser -Cleanup $cleanup -PersistEvidence $save -Confirm:$false } 'alreadyStarted'
Reset-Run
$failingBrowser = { throw 'sensitive arbitrary browser error' }
Assert-Rejected { Invoke-AcceptanceRun $context $journal $consent ('a' * 64) @{} 'unused' $seed $persist -Browser $failingBrowser -Cleanup $cleanup -PersistEvidence $save -Confirm:$false } 'journeyFailed'
Assert-True ($calls.Contains('Cleanup') -and $journal.acceptance.status -ceq 'Failed' -and $journal.acceptance.cleanupStatus -ceq 'Destroyed') 'Failed journeys must still retire the instance.'
Assert-True (-not ($evidence | ConvertTo-Json -Depth 20).Contains('sensitive arbitrary')) 'Uncontrolled browser text must not enter evidence.'
Reset-Run
$failingSeed = { throw 'lifecycle.acceptance.seedFailed' }
Assert-Rejected { Invoke-AcceptanceRun $context $journal $consent ('a' * 64) @{} 'unused' $failingSeed $persist -Browser $browser -Cleanup $cleanup -PersistEvidence $save -Confirm:$false } 'seedFailed'
Assert-True ($calls.Contains('Cleanup') -and -not $calls.Contains('Browser')) 'Seed failure must clean up without running the browser.'
Reset-Run
$failingCleanup = { throw 'uncontrolled Azure error' }
Assert-Rejected { Invoke-AcceptanceRun $context $journal $consent ('a' * 64) @{} 'unused' $seed $persist -Browser $browser -Cleanup $failingCleanup -PersistEvidence $save -Confirm:$false } 'cleanupFailed'
Assert-True ($journal.acceptance.journeySucceeded -and $journal.acceptance.cleanupStatus -ceq 'Failed') 'A successful journey must not hide failed cleanup.'
Reset-Run
$failingSave = { throw 'lifecycle.azure.objectNotDurable' }
Assert-Rejected { Invoke-AcceptanceRun $context $journal $consent ('a' * 64) @{} 'unused' $seed $persist -Browser $browser -Cleanup $cleanup -PersistEvidence $failingSave -Confirm:$false } 'objectNotDurable'
Assert-True (-not $calls.Contains('Cleanup')) 'Do not erase data before the evidence is durable.'
Reset-Run
Invoke-AcceptanceRun $context $journal $consent ('a' * 64) @{} 'unused' $seed $persist -Browser $browser -Cleanup $cleanup -PersistEvidence $save -WhatIf
Assert-True ($calls.Count -eq 0) 'WhatIf must not write or run jobs.'

# Exercise the real cleanup coordinator and lifecycle engine, replacing only Azure/Terraform I/O.
Import-Module (Join-Path $repository 'scripts/LifecycleNative.psm1') -Force
$previousUsername = $env:HEXAGON_E2E_USERNAME; $previousPassword = $env:HEXAGON_E2E_PASSWORD
try {
    $env:HEXAGON_E2E_USERNAME = 'fixture-user'; $env:HEXAGON_E2E_PASSWORD = 'fixture-password'
    $probe = Invoke-LifecycleCommand pwsh @('-NoProfile', '-NonInteractive', '-Command', '@{ usernamePresent = [bool] $env:HEXAGON_E2E_USERNAME; passwordPresent = [bool] $env:HEXAGON_E2E_PASSWORD } | ConvertTo-Json -Compress') -TimeoutSeconds 30
    $facts = $probe.text | ConvertFrom-Json -AsHashtable
    Assert-True ($probe.exitCode -eq 0 -and -not $facts.usernamePresent -and -not $facts.passwordPresent) 'Non-browser child processes must not inherit test credentials.'
    Assert-Rejected { Invoke-LifecycleCommand acceptance-browser @([IO.Path]::GetFullPath((Join-Path $repository 'examples/environment-inventory.json'))) -Environment @{ NODE_OPTIONS = '--inspect' } } 'environmentForbidden'
}
finally { $env:HEXAGON_E2E_USERNAME = $previousUsername; $env:HEXAGON_E2E_PASSWORD = $previousPassword }

$script:cleanupCalls = [Collections.Generic.List[string]]::new(); $script:failRoot = ''
$script:durableInventory = $null
$port = {
    param($request)
    switch ($request.action) {
        Preflight {
            return @{ verified = $true; tenantId = $request.target.tenantId; subscriptionId = $request.target.subscriptionId; clientId = $request.target.clientId
                product = $request.product; environment = $request.environment; instanceId = $request.instanceId
                configurationSha256 = $request.root.configurationSha256; inputsSha256 = $request.root.inputsSha256; iacSnapshotSha256 = 'a' * 64
                stateKey = $request.root.stateKey; container = $request.target.container; planVerified = $true
                binarySha256 = $request.root.plan.binarySha256; jsonSha256 = $request.root.plan.jsonSha256 }
        }
        DestructionSafety { return @{ quiesced = $true; backupVerified = $false; evidenceSha256 = 'd' * 64; product = $request.product; environment = $request.environment; instanceId = $request.instanceId; rootId = $request.root.id } }
        Persist {
            $script:durableInventory = Get-Content -Raw $request.inventoryPath | ConvertFrom-Json -AsHashtable
            return @{ durable = $true; sha256 = $request.sha256; revision = $request.revision; journalKey = "$($request.product)/$($request.environment)/$($request.instanceId)/inventory.json"
                container = $request.target.container; storageAccount = $request.target.storageAccount; snapshotSha256 = 'a' * 64 }
        }
        Apply {
            if (@($script:durableInventory.roots | Where-Object id -CEQ $request.root.id)[0].status -cne 'Destroying') { throw 'Intent must be persisted before applying.' }
            $script:cleanupCalls.Add("Apply:$($request.root.id)")
            return @{ exitCode = $(if ($script:failRoot -ceq $request.root.id) { 1 } else { 0 }) }
        }
        Observe {
            return @{ stateStatus = 'Present'; scopeAccessible = $true; scopeComplete = $true; lineage = $request.root.stateLineage; serial = $request.root.stateSerial + 1
                resources = @(); remainingResourceIds = @(); configurationConverged = $true; probes = @($request.root.resources | ForEach-Object { @{ id = $_.id; status = 'Missing' } }) }
        }
        default { throw 'Unexpected cleanup port action.' }
    }
}
$cleanupModule = Get-Module AcceptanceCleanup
& $cleanupModule {
    param($testPort)
    $script:testPort = $testPort
    function script:Invoke-AzureLifecycleQuiesce { [CmdletBinding(SupportsShouldProcess)] param($Context) }
    function script:New-AzureLifecyclePort { param($Context) return $script:testPort }
    function script:Save-AzureLifecycleJournal { param($Context, $Path) }
    function script:Publish-AzureLifecycleObject { [CmdletBinding(SupportsShouldProcess)] param($Context, $Key, $Bytes, $Sha256) }
    function script:New-AzureLifecyclePlan {
        [CmdletBinding(SupportsShouldProcess)] param($Context, $Root, $Operation)
        $binary = Join-Path $Context.runtime "$($Root.id).tfplan"
        [IO.File]::WriteAllText($binary, 'protocol-plan')
        $changes = @($Root.resources | Where-Object current | ForEach-Object { @{ mode = 'managed'; address = $_.address; type = $_.type; change = @{ actions = @('delete'); before = @{ id = $_.id }; after = $null } } })
        $plan = @{ format_version = '1.2'; errored = $false; complete = $true; resource_changes = $changes }
        [IO.File]::WriteAllText("$binary.json", ($plan | ConvertTo-Json -Depth 30))
        return @{ binaryPath = $binary; jsonPath = "$binary.json" }
    }
} $port
try {
    foreach ($failure in @('', 'messaging')) {
        $workspace = Join-Path $repository "artifacts/acceptance-cleanup-$([guid]::NewGuid().ToString('N'))"
        [IO.Directory]::CreateDirectory($workspace) | Out-Null
        [IO.File]::WriteAllText((Join-Path $workspace 'inventory.json'), (ConvertTo-PlatformBootstrapJson $inventory))
        $context = @{ inventory = Copy-Value $inventory; prefix = 'fixture'; runtime = $workspace }
        $script:cleanupCalls.Clear(); $script:failRoot = $failure
        if ($failure) {
            Assert-Rejected { Invoke-AcceptanceCleanup $context $consent $workspace -Confirm:$false } 'applyFailed'
            Assert-True (($cleanupCalls -join ',') -ceq 'Apply:messaging') 'A failed dependency deletion must prevent deleting hosting.'
        }
        else {
            Invoke-AcceptanceCleanup $context $consent $workspace -Confirm:$false
            Assert-True (($cleanupCalls -join ',') -ceq 'Apply:messaging,Apply:hosting') 'Cleanup must use reverse dependency order.'
            Assert-True (@($context.inventory.roots | Where-Object status -CNE 'Destroyed').Count -eq 0) 'The real engine must confirm retirement of both roots.'
        }
    }
}
finally { Import-Module (Join-Path $repository 'scripts/AcceptanceCleanup.psm1') -Force }
Write-Host "Acceptance protocol tests passed: $script:assertions assertions; no cloud calls."
