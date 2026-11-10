<#
.SYNOPSIS
    Exercises the lifecycle engine through a protocol double, never cloud or Terraform apply.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$rootDirectory = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $rootDirectory 'scripts/EnvironmentLifecycle.psm1') -Force
$template = Get-Content -Raw -LiteralPath (Join-Path $rootDirectory 'examples/environment-inventory.json')
$parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
$temporary = Join-Path $parent "hexagon-lifecycle-tests-$([guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($temporary) | Out-Null
$script:assertions = 0
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message }; $script:assertions++ }
function Assert-Rejected([scriptblock] $Action, [string] $Code) {
    try { & $Action | Out-Null }
    catch { Assert-True ($_.Exception.Message -like "*$Code*") "Unexpected rejection: $($_.Exception.Message)"; return }
    throw "Expected rejection: $Code"
}
function Get-Fixture { return $template | ConvertFrom-Json -AsHashtable }
function New-FixturePath {
    $directory = Join-Path $temporary ([guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $path = Join-Path $directory 'inventory.json'
    New-EnvironmentInventory (Get-Fixture) $path | Out-Null
    return $path
}
function Write-Fixture([object] $Value, [string] $Path) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 32))
}
function Reset-Port {
    $script:calls = [Collections.Generic.List[object]]::new()
    $script:states = @{}
    $script:failApply = ''; $script:failPersist = $false; $script:wrongTarget = $false
    $script:unavailable = $false; $script:denied = $false; $script:remaining = $false; $script:backup = $true
    $script:lineage = '44444444-4444-4444-4444-444444444444'
    $script:durable = @{}
}
$port = {
    param($request)
    $script:calls.Add($request)
    $id = $request.root.id
    switch ($request.action) {
        'Preflight' {
            return @{ verified = $true; tenantId = $request.target.tenantId; subscriptionId = $(if ($script:wrongTarget) { 'foreign' } else { $request.target.subscriptionId }); clientId = $request.target.clientId
                product = $request.product; environment = $request.environment; instanceId = $request.instanceId
                configurationSha256 = $request.root.configurationSha256; inputsSha256 = $request.root.inputsSha256
                iacSnapshotSha256 = 'a' * 64; stateKey = $request.root.stateKey; container = $request.target.container
                planVerified = $true; binarySha256 = $(if ($null -ne $request.root.plan) { $request.root.plan.binarySha256 } else { $null })
                jsonSha256 = $(if ($null -ne $request.root.plan) { $request.root.plan.jsonSha256 } else { $null }) }
        }
        'Persist' {
            if ($script:failPersist) { throw 'never-log-this-storage-secret' }
            $script:durable = Get-Content -Raw -LiteralPath $request.inventoryPath | ConvertFrom-Json -AsHashtable
            return @{ durable = $true; sha256 = $request.sha256; revision = $request.revision
                journalKey = "$($request.product)/$($request.environment)/$($request.instanceId)/inventory.json"
                container = $request.target.container; storageAccount = $request.target.storageAccount; snapshotSha256 = 'a' * 64 }
        }
        'DestructionSafety' { return @{ quiesced = $true; evidenceSha256 = 'c' * 64; backupVerified = $script:backup
            product = $request.product; environment = $request.environment; instanceId = $request.instanceId; rootId = $request.root.id } }
        'Apply' {
            $checkpoint = @($script:durable.roots | Where-Object id -CEQ $id)[0]
            if ($checkpoint.status -cnotin @('Applying', 'Destroying')) { throw 'Apply preceded its durable intent checkpoint.' }
            $resourceId = "/subscriptions/$($request.target.subscriptionId)/resourceGroups/$($request.root.resourceGroup)/providers/Microsoft.Network/virtualNetworks/test"
            if (-not $script:states.ContainsKey($id)) { $script:states[$id] = @{ serial = 0; resources = @(); converged = $false } }
            $state = $script:states[$id]; $state.serial++
            if ($request.operation -ceq 'Create') {
                $state.resources = @(@{ id = $resourceId; address = 'azurerm_virtual_network.test'; type = 'azurerm_virtual_network' })
                $state.converged = $script:failApply -cne $id
            }
            elseif ($script:failApply -cne $id) { $state.resources = @() }
            if ($script:failApply -ceq $id) { return @{ exitCode = 1 } }
            return @{ exitCode = 0 }
        }
        'Observe' {
            $state = $script:states[$id]
            $all = @{}
            foreach ($resource in @($request.root.resources) + @($state.resources)) { $all[$resource.id] = $resource }
            $probes = @($all.Keys | ForEach-Object { @{ id = $_; status = $(if ($script:denied) { 'Denied' } elseif (@($state.resources | Where-Object id -IEQ $_).Count -gt 0) { 'Present' } else { 'Missing' }) } })
            $remaining = @(); if ($script:remaining) { $remaining = @('untracked-resource') }
            return @{ stateStatus = $(if ($script:unavailable) { 'Unavailable' } else { 'Present' }); scopeAccessible = $true; scopeComplete = $true
                lineage = $script:lineage; serial = $state.serial; resources = $state.resources; probes = $probes
                configurationConverged = $state.converged; remainingResourceIds = $remaining }
        }
        default { throw 'Unexpected lifecycle port action.' }
    }
}
function Add-Plan([string] $Path, [string] $RootId, [string] $Operation) {
    $inventory = Read-EnvironmentInventory $Path
    $target = @($inventory.roots | Where-Object id -CEQ $RootId)[0]
    $changes = @()
    if ($Operation -ceq 'Destroy') {
        foreach ($resource in $target.resources) {
            if ($resource.presence -ceq 'Missing') { continue }
            $changes += @{ address = $resource.address; type = $resource.type; mode = 'managed'; change = @{ actions = @('delete'); before = @{ id = $resource.id }; after = $null } }
        }
    }
    $plan = @{ format_version = '1.2'; errored = $false; complete = $true; resource_changes = $changes }
    $binary = Join-Path ([IO.Path]::GetDirectoryName($Path)) "$RootId.tfplan"
    $json = "$binary.json"
    [IO.File]::WriteAllText($binary, "test-binary-$([guid]::NewGuid().ToString('N'))")
    Write-Fixture $plan $json
    $hash = Add-EnvironmentRootPlan -InventoryPath $Path -RootId $RootId -Operation $Operation -BinaryPath $binary -JsonPath $json -ExpectedInventorySha256 (Get-LifecycleFileHash $Path)
    return @{ InventoryPath = $Path; RootId = $RootId; BinaryPath = $binary; JsonPath = $json; ReviewSha256 = $hash; Confirmation = "$($Operation.ToUpperInvariant()) $($inventory.product) $($inventory.environment) $($inventory.instance.id)"; Port = $port }
}
try {
    $inventory = Get-Fixture
    Assert-EnvironmentInventory $inventory
    Assert-True ((@(Get-EnvironmentRootOrder $inventory Create) -join ',') -ceq 'hosting,messaging') 'Create order ignored dependencies.'
    Assert-True ((@(Get-EnvironmentRootOrder $inventory Destroy) -join ',') -ceq 'messaging,hosting') 'Destroy order was not reversed.'
    foreach ($mutation in @(
        { param($i) $i.roots[0].stateKey = 'hexagon-template/dev/persistent/hosting.tfstate' },
        { param($i) $i.instance.id = 'persistent' },
        { param($i) $i.roots[0].resourceGroup = 'rg-hexagon-template-dev-hosting' },
        { param($i) $i.roots[1].dependsOn = @() },
        { param($i) $i.target.container = 'tfstate-prod' },
        { param($i) $i.target.tenantId = '00000000-0000-0000-0000-000000000000' },
        { param($i) $i.clientSecret = 'never-log-this-secret' }
    )) {
        $bad = Get-Fixture; & $mutation $bad
        Assert-Rejected { Assert-EnvironmentInventory $bad } 'lifecycle.'
    }
    $bad = Get-Fixture; $bad.target.stateResourceGroup = $bad.roots[0].resourceGroup
    Assert-Rejected { Assert-EnvironmentInventory $bad } 'lifecycle.bootstrapProtected'
    $bad = Get-Fixture; $bad.roots[0].dependsOn = @('messaging')
    Assert-Rejected { Assert-EnvironmentInventory $bad } 'lifecycle.dependencyCycle'
    $bad = Get-Fixture; $bad.components = @('backend'); $bad.roots = @($bad.roots[1]); $bad.roots[0].dependsOn = @()
    Assert-Rejected { Assert-EnvironmentInventory $bad } 'lifecycle.componentUncovered'
    $bad = Get-Fixture; $bad.components = @('web')
    Assert-Rejected { Assert-EnvironmentInventory $bad } 'lifecycle.componentUncovered'
    $path = New-FixturePath
    Assert-Rejected { New-EnvironmentInventory (Get-Fixture) $path } 'exists'
    $held = [IO.File]::Open("$path.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { Assert-Rejected { New-EnvironmentInventory (Get-Fixture) "$path" } 'lifecycle.inventoryLocked' } finally { $held.Dispose() }

    $fixtureRoot = $inventory.roots[0]
    $plan = @{ format_version = '1.2'; errored = $false; complete = $true; resource_changes = @(@{ address = 'azurerm_virtual_network.test'; type = 'azurerm_virtual_network'; mode = 'managed'; change = @{ actions = @('create'); before = $null; after = @{ resource_group_name = $fixtureRoot.resourceGroup } } }) }
    Assert-EnvironmentTerraformPlan $inventory $fixtureRoot Create $plan; $script:assertions++
    Assert-EnvironmentTerraformPlan $inventory $fixtureRoot Create @{ format_version = '1.2'; errored = $false; complete = $true }; $script:assertions++
    Assert-Rejected { Assert-EnvironmentTerraformPlan $inventory $fixtureRoot Create @{ format_version = '1.2'; errored = $false; complete = $true; action_invocations = @(@{ type = 'unapproved' }) } } 'lifecycle.planIncomplete'
    $plan.resource_changes[0].change.actions = @('delete', 'create')
    Assert-Rejected { Assert-EnvironmentTerraformPlan $inventory $fixtureRoot Create $plan } 'lifecycle.planOperationMismatch'
    $plan.resource_changes[0].change.actions = @('create')
    Assert-Rejected { Assert-EnvironmentTerraformPlan $inventory $fixtureRoot Destroy $plan } 'lifecycle.planOperationMismatch'
    $plan.resource_changes[0].change.after.resource_group_name = 'rg-foreign'
    Assert-Rejected { Assert-EnvironmentTerraformPlan $inventory $fixtureRoot Create $plan } 'lifecycle.planScopeMismatch'
    $plan.resource_changes[0].change.after.resource_group_name = $fixtureRoot.resourceGroup
    $plan.resource_changes[0].type = 'azurerm_resource_group'
    Assert-Rejected { Assert-EnvironmentTerraformPlan $inventory $fixtureRoot Create $plan } 'lifecycle.planResourceForbidden'
    $plan.complete = $false
    Assert-Rejected { Assert-EnvironmentTerraformPlan $inventory $fixtureRoot Create $plan } 'lifecycle.planIncomplete'

    Reset-Port
    $path = New-FixturePath
    Assert-Rejected { Add-Plan $path messaging Create } 'lifecycle.dependencyNotReady'
    $arguments = Add-Plan $path hosting Create
    $crossRoot = Read-EnvironmentInventory $path
    $crossRoot.roots[0].plan.rootId = 'messaging'; Write-Fixture $crossRoot $path
    Assert-Rejected { Read-EnvironmentInventory $path } 'lifecycle.planRootMismatch'
    $crossRoot.roots[0].plan.rootId = 'hosting'; Write-Fixture $crossRoot $path
    $changedState = Read-EnvironmentInventory $path
    $changedState.roots[0].stateLineage = '66666666-6666-6666-6666-666666666666'; $changedState.roots[0].stateSerial = 1
    Write-Fixture $changedState $path
    Assert-Rejected { Invoke-EnvironmentRootOperation @arguments } 'lifecycle.reviewStale'
    $changedState.roots[0].stateLineage = $null; $changedState.roots[0].stateSerial = 0
    Write-Fixture $changedState $path
    $expired = Read-EnvironmentInventory $path
    $expired.roots[0].plan.createdAt = [DateTimeOffset]::UtcNow.AddDays(-2).ToUnixTimeSeconds()
    $envelope = @{} + $expired.roots[0].plan; $envelope.Remove('reviewSha256')
    $expired.roots[0].plan.reviewSha256 = & (Get-Module EnvironmentLifecycle) { param($value) Get-LifecycleValueHash $value } $envelope
    $arguments.ReviewSha256 = $expired.roots[0].plan.reviewSha256
    Write-Fixture $expired $path
    Assert-Rejected { Invoke-EnvironmentRootOperation @arguments } 'lifecycle.reviewStale'
    $arguments = Add-Plan $path hosting Create
    $wrong = @{} + $arguments; $wrong.Confirmation = 'CREATE hexagon-template dev persistent'
    Assert-Rejected { Invoke-EnvironmentRootOperation @wrong } 'lifecycle.confirmationMismatch'
    Assert-True ($script:calls.Count -eq 0) 'Incorrect selection reached the port.'
    $wrong = @{} + $arguments; $wrong.ReviewSha256 = '0' * 64
    Assert-Rejected { Invoke-EnvironmentRootOperation @wrong } 'lifecycle.reviewStale'
    $before = Get-LifecycleFileHash $path
    Invoke-EnvironmentRootOperation @arguments -WhatIf | Out-Null
    Sync-EnvironmentRoot -InventoryPath $path -RootId hosting -Port $port -WhatIf | Out-Null
    Add-EnvironmentRootPlan -InventoryPath $path -RootId hosting -Operation Create -BinaryPath $arguments.BinaryPath -JsonPath $arguments.JsonPath -ExpectedInventorySha256 $before -WhatIf | Out-Null
    Assert-True ((Get-LifecycleFileHash $path) -ceq $before -and $script:calls.Count -eq 0) 'An API WhatIf wrote an inventory or called the integration port.'
    $whatIfNew = Join-Path ([IO.Path]::GetDirectoryName($path)) 'whatif-new.json'
    New-EnvironmentInventory (Get-Fixture) $whatIfNew -WhatIf | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $whatIfNew) -and -not (Test-Path -LiteralPath "$whatIfNew.lock")) 'Constructor WhatIf created inventory files.'
    [IO.File]::AppendAllText($arguments.BinaryPath, 'tampered')
    Assert-Rejected { Invoke-EnvironmentRootOperation @arguments } 'lifecycle.reviewStale'
    $arguments = Add-Plan $path hosting Create
    $script:wrongTarget = $true
    Assert-Rejected { Invoke-EnvironmentRootOperation @arguments } 'lifecycle.preflightMismatch'
    Assert-True (@($script:calls | Where-Object action -CEQ Apply).Count -eq 0) 'Wrong subscription reached Apply.'
    $script:wrongTarget = $false; $script:failPersist = $true
    Assert-Rejected { Invoke-EnvironmentRootOperation @arguments } 'lifecycle.recoveryCheckpointFailed'
    Assert-True (@($script:calls | Where-Object action -CEQ Apply).Count -eq 0) 'Apply ran without a durable intent checkpoint.'

    Reset-Port; $path = New-FixturePath
    $arguments = Add-Plan $path hosting Create
    $crashed = Read-EnvironmentInventory $path
    $crashed.roots[0].status = 'Applying'; $crashed.roots[0].lastOperation = 'Create'
    Write-Fixture $crashed $path
    Assert-Rejected { Add-Plan $path hosting Create } 'lifecycle.reconciliationRequired'

    Reset-Port; $path = New-FixturePath
    $production = Get-Content -Raw -LiteralPath $path
    $production = $production.Replace('"dev"', '"prod"').Replace('/dev/', '/prod/').Replace('-dev-', '-prod-').Replace('"tfstate-dev"', '"tfstate-prod"').Replace('-run-12345-1-', '-').Replace('run-12345-1', 'persistent').Replace('Ephemeral', 'Persistent').Replace('DeletePersistent', 'BackupRequired')
    [IO.File]::WriteAllText($path, $production)
    foreach ($id in @('hosting', 'messaging')) { $arguments = Add-Plan $path $id Create; Invoke-EnvironmentRootOperation @arguments | Out-Null }
    $arguments = Add-Plan $path messaging Destroy
    $script:backup = $false
    Assert-Rejected { Invoke-EnvironmentRootOperation @arguments } 'lifecycle.destructionSafetyMissing'
    Assert-True (@($script:calls | Where-Object { $_.action -ceq 'Apply' -and $_.operation -ceq 'Destroy' }).Count -eq 0) 'Production destroy ran without backup evidence.'

    Reset-Port; $path = New-FixturePath
    $arguments = Add-Plan $path hosting Create
    $result = Invoke-EnvironmentRootOperation @arguments
    Assert-True ($result.status -ceq 'Verified' -and -not $result.applicationVerified) 'Infrastructure verification claimed application readiness.'
    $arguments = Add-Plan $path messaging Create
    Invoke-EnvironmentRootOperation @arguments | Out-Null
    Assert-Rejected { Add-Plan $path hosting Destroy } 'lifecycle.dependentNotDestroyed'
    $arguments = Add-Plan $path messaging Destroy
    $result = Invoke-EnvironmentRootOperation @arguments
    Assert-True ($result.status -ceq 'Destroyed') 'Messaging was not retired first.'
    $arguments = Add-Plan $path hosting Destroy
    $script:remaining = $true
    Assert-Rejected { Invoke-EnvironmentRootOperation @arguments } 'lifecycle.destructionNotVerified'
    $after = Read-EnvironmentInventory $path
    Assert-True ($after.roots[0].status -ceq 'Failed' -and (Test-Path -LiteralPath $path)) 'Incomplete destruction lost its recovery record.'
    $script:remaining = $false
    $result = Sync-EnvironmentRoot -InventoryPath $path -RootId hosting -Port $port
    Assert-True ($result.status -ceq 'Destroyed') 'Interrupted destruction did not reconcile.'
    $saved = Read-EnvironmentInventory $path
    Assert-True (@($saved.roots | Where-Object status -CNE Destroyed).Count -eq 0 -and $saved.roots[0].resources.Count -eq 1) 'Destroy removed historical IDs or left an active root.'
    Assert-True ($script:durable.revision -eq $saved.revision) 'The last inventory revision was not durable.'

    Reset-Port; $path = New-FixturePath
    $script:failApply = 'hosting'
    $arguments = Add-Plan $path hosting Create
    Assert-Rejected { Invoke-EnvironmentRootOperation @arguments } 'lifecycle.applyFailed'
    Assert-Rejected { Add-Plan $path messaging Create } 'lifecycle.dependencyNotReady'
    $result = Sync-EnvironmentRoot -InventoryPath $path -RootId hosting -Port $port
    $partial = Read-EnvironmentInventory $path
    Assert-True ($result.status -ceq 'Failed' -and $partial.roots[0].resources.Count -eq 1) 'Partial apply was claimed complete or lost its created resource.'
    $script:failApply = ''
    $arguments = Add-Plan $path hosting Create
    Invoke-EnvironmentRootOperation @arguments | Out-Null
    $script:denied = $true
    $result = Sync-EnvironmentRoot -InventoryPath $path -RootId hosting -Port $port
    Assert-True ($result.status -ceq 'Failed') 'Access denied was treated as verified absence.'
    $script:denied = $false; $script:unavailable = $true
    $result = Sync-EnvironmentRoot -InventoryPath $path -RootId hosting -Port $port
    Assert-True ($result.status -ceq 'Failed') 'Inaccessible state was treated as empty.'
    $script:unavailable = $false; $script:lineage = '55555555-5555-5555-5555-555555555555'
    $result = Sync-EnvironmentRoot -InventoryPath $path -RootId hosting -Port $port
    Assert-True ($result.status -ceq 'Failed') 'A foreign lineage was accepted.'

    Reset-Port; $path = New-FixturePath
    $arguments = Add-Plan $path hosting Create
    Push-Location $rootDirectory
    try {
        foreach ($field in @('InventoryPath', 'BinaryPath', 'JsonPath')) { $arguments[$field] = [IO.Path]::GetRelativePath($rootDirectory, $arguments[$field]) }
        $arguments.Port = { param($request) if ($request.action -ceq 'Persist') { Set-Location $script:temporary }; & $script:port $request }
        $result = Invoke-EnvironmentRootOperation @arguments
        Assert-True ($result.status -ceq 'Verified' -and (Read-EnvironmentInventory $path).roots[0].status -ceq 'Verified') 'An adapter working-directory change redirected the inventory or plan.'
    }
    finally { Pop-Location }

    $entry = Join-Path $rootDirectory 'scripts/Test-EnvironmentInventory.ps1'
    $json = & pwsh -NoProfile -File $entry -Inventory (Join-Path $rootDirectory 'examples/environment-inventory.json') -Environment dev -InstanceId run-12345-1 -Operation Destroy
    $output = $json -join "`n" | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and ($output.order -join ',') -ceq 'messaging,hosting') 'CLI did not return a flat destruction order.'
    $json = & pwsh -NoProfile -File $entry -Inventory (Join-Path $rootDirectory 'examples/environment-inventory.json') -Environment prod -InstanceId run-12345-1
    Assert-True ($LASTEXITCODE -eq 1 -and ($json -join "`n" | ConvertFrom-Json).code -ceq 'lifecycle.selectionMismatch') 'CLI accepted another selected environment.'
    $newEntry = Join-Path $rootDirectory 'scripts/New-EnvironmentInventory.ps1'
    $output = Join-Path $rootDirectory "artifacts/lifecycle-whatif-$([guid]::NewGuid().ToString('N'))/inventory.json"
    $json = & pwsh -NoProfile -File $newEntry -Definition (Join-Path $rootDirectory 'examples/environment-inventory.json') -Environment dev -InstanceId run-12345-1 -Output $output -WhatIf
    Assert-True ($LASTEXITCODE -eq 2 -and ($json -join "`n" | ConvertFrom-Json).status -ceq 'Unverified' -and -not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($output)))) 'WhatIf wrote an inventory or returned a successful creation.'
}
finally {
    $resolved = [IO.Path]::GetFullPath($temporary)
    if ([IO.Path]::GetDirectoryName($resolved) -cne $parent -or -not [IO.Path]::GetFileName($resolved).StartsWith('hexagon-lifecycle-tests-')) { throw 'Unsafe lifecycle test cleanup.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host "Environment lifecycle tests passed: $script:assertions assertions; protocol double, no cloud changes."
