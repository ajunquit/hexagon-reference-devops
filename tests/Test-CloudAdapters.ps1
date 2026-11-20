<#
.SYNOPSIS
    Tests that every cloud adapter and every set of environment rules of the repository implements the
    whole contract, and that neither serves a target that no cloud recognizes.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repository 'scripts/CloudAdapters.psm1') -Force
Import-Module (Join-Path $repository 'scripts/EnvironmentLifecycle.psm1') -Force
Import-Module (Join-Path $repository 'scripts/ContractSchemas.psm1') -Force
$script:assertions = 0
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message }; $script:assertions++ }

$contract = @('Test-CloudTarget', 'Get-CloudName', 'Get-CloudTargetDetails', 'Get-CloudEnvironmentEntry', 'Get-CloudEnvironmentResultVersion',
    'Get-CloudStoreDescription', 'Test-CloudDeliveryStage', 'Enter-CloudLifecycle', 'Get-CloudLifecycleJournal', 'Exit-CloudLifecycle', 'Invoke-CloudApplicationStage')
$adapters = @(& (Get-Module CloudAdapters) { Get-CloudAdapters })
# The base alone has no cloud: every check below then holds trivially and an unknown target is still rejected.
$names = @{}
foreach ($adapter in $adapters) {
    Assert-True ($adapter.ExportedFunctions.Count -eq 0) "$($adapter.Name) must not export functions."
    foreach ($function in $contract) {
        Assert-True ([bool] (& $adapter { param($name) Get-Command $name -CommandType Function -ErrorAction SilentlyContinue } $function)) "$($adapter.Name) does not implement $function."
    }
    $name = Invoke-CloudAdapter $adapter Get-CloudName
    Assert-True ($name -cmatch '^[a-z]+$' -and -not $names.ContainsKey($name)) "$($adapter.Name) has an invalid or repeated cloud name."
    $names[$name] = $true
    $entry = Join-Path $repository "scripts/$(Invoke-CloudAdapter $adapter Get-CloudEnvironmentEntry)"
    Assert-True (Test-Path -LiteralPath $entry -PathType Leaf) "$($adapter.Name) points to a missing environment entry."
    Assert-True ((Invoke-CloudAdapter $adapter Get-CloudEnvironmentResultVersion) -cmatch "^hexagon[.]ec/$name-environment-result/v1$") "$($adapter.Name) declares another result version."
    foreach ($stage in @('Validate', 'Artifacts', 'Migrations', 'PublishWeb', 'Acceptance')) {
        Assert-True (Invoke-CloudAdapter $adapter Test-CloudDeliveryStage @($stage)) "$($adapter.Name) rejects the common stage $stage."
    }
}

try { Get-CloudAdapter @{ target = @{ unknown = 'target' } } | Out-Null; throw 'An unknown target was served.' }
catch { Assert-True ($_.Exception.Message -ceq 'lifecycle.cloud.targetUnsupported') "Unexpected rejection: $($_.Exception.Message)" }

$rulesContract = @('Test-EnvironmentRulesTarget', 'Test-EnvironmentRulesAdapter', 'Assert-EnvironmentRulesTarget', 'Get-EnvironmentRulesRootAdapter',
    'Assert-EnvironmentRulesRootScope', 'Get-EnvironmentRulesRootBinding', 'ConvertTo-EnvironmentRulesResourceId', 'Assert-EnvironmentRulesResource',
    'Test-EnvironmentRulesPlanTypeForbidden', 'Assert-EnvironmentRulesPlanScope', 'Test-EnvironmentRulesPreflightTarget', 'Test-EnvironmentRulesStore',
    'Get-EnvironmentRulesRootPaths', 'Test-EnvironmentRulesInputsScope')
$rules = @(& (Get-Module EnvironmentLifecycle) { Get-EnvironmentRuleModules })
Assert-True ($rules.Count -eq $adapters.Count) 'Every cloud adapter needs its environment rules, and only those.'
$owners = @{}
foreach ($module in $rules) {
    Assert-True ($module.ExportedFunctions.Count -eq 0) "$($module.Name) must not export functions."
    foreach ($function in $rulesContract) {
        Assert-True ([bool] (& $module { param($name) Get-Command $name -CommandType Function -ErrorAction SilentlyContinue } $function)) "$($module.Name) does not implement $function."
    }
    foreach ($id in @('hosting', 'messaging')) {
        $adapter = Invoke-EnvironmentRules $module Get-EnvironmentRulesRootAdapter @($id)
        Assert-True ($adapter -cmatch '^[A-Z][A-Za-z]+$' -and -not $owners.ContainsKey($adapter)) "$($module.Name) has an invalid or repeated adapter for $id."
        $owners[$adapter] = $true
        Assert-True (Invoke-EnvironmentRules $module Test-EnvironmentRulesAdapter @($adapter)) "$($module.Name) does not own its adapter $adapter."
        foreach ($path in @(Invoke-EnvironmentRules $module Get-EnvironmentRulesRootPaths @($adapter, $id, 'dev'))) {
            Assert-True (Test-Path -LiteralPath (Join-Path $repository $path) -PathType Container) "$($module.Name) packages a missing directory: $path."
        }
    }
}
try { Get-EnvironmentRules @{ target = @{ unknown = 'target' } } | Out-Null; throw 'Unknown environment rules were served.' }
catch { Assert-True ($_.Exception.Message -ceq 'lifecycle.cloud.targetUnsupported') "Unexpected rejection: $($_.Exception.Message)" }

# Every contract with cloud slots has one variant per cloud of the repository, and only those; RabbitMQ,
# the messaging provider of the core, may add its own.
$schemas = Join-Path $repository 'contracts/schemas'
$clouds = @($names.Keys | Sort-Object)
foreach ($variant in @(Get-ChildItem -LiteralPath $schemas -Filter '*.variant.json' -File)) {
    Assert-True ($variant.Name -cmatch '^([a-z]+)-([a-z][a-z0-9-]*-v[1-9][0-9]*)[.]variant[.]json$' -and ($names.ContainsKey($Matches[1]) -or $Matches[1] -ceq 'rabbitmq') -and
        (Test-Path -LiteralPath (Join-Path $schemas "$($Matches[2]).schema.json"))) "$($variant.Name) names no cloud or contract of the repository."
}
$sloted = 0
foreach ($schema in @(Get-ChildItem -LiteralPath $schemas -Filter '*.schema.json' -File)) {
    $definitions = (Get-Content -Raw -LiteralPath $schema.FullName | ConvertFrom-Json -AsHashtable -Depth 64)['$defs']
    if ($null -eq $definitions -or @($definitions.Keys | Where-Object { $_ -cmatch '^cloud[A-Z]' }).Count -eq 0) { continue }
    $contract = $schema.Name -replace '[.]schema[.]json$', ''
    $present = @($clouds | Where-Object { Test-Path -LiteralPath (Join-Path $schemas "$_-$contract.variant.json") })
    Assert-True ($present.Count -eq $clouds.Count) "$contract needs a variant for every cloud of the repository."
    Assert-True (-not ('{}' | Test-Json -Schema (Get-ContractSchema $contract) -ErrorAction SilentlyContinue)) "$contract accepts an empty document."
    $sloted++
}
Assert-True ($sloted -ge 1) 'No contract declares cloud slots.'

Write-Host "Cloud adapter contract passed ($script:assertions assertions, $($adapters.Count) adapters, $($rules.Count) sets of environment rules, $sloted contracts with cloud variants)."
