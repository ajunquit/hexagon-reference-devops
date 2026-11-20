<#
.SYNOPSIS
    Checks per-consumer operations, retention, identity isolation and generated Prometheus rules.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts/MessagingOperations.psm1') -Force
function Copy-Model($Value) { $Value | ConvertTo-Json -Depth 30 | ConvertFrom-Json }
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-Rejected([scriptblock] $Action, [string] $Expected) {
    try { & $Action | Out-Null }
    catch {
        if ($_.Exception.Message -notlike "*$Expected*") { throw "Unexpected validation failure: $($_.Exception.Message)" }
        return
    }
    throw "Expected rejection: $Expected"
}
$rabbit = Get-Content -Raw (Join-Path $root 'examples/rabbitmq-policy.json') | ConvertFrom-Json
$policy = Get-Content -Raw (Join-Path $root 'examples/messaging-operations-policy.json') | ConvertFrom-Json
Assert-OperationsPolicy $policy $rabbit
$inputModel = ConvertTo-OperationsTerraformInput $policy $rabbit
Assert-True ($null -eq $inputModel.operations.consumers.worker.dead_letter_threshold) 'A disabled DLQ must not create an alert.'
Assert-True ($inputModel.operations.consumers.'sales-worker'.dead_letter_threshold -eq 1) 'DLQ threshold lost.'
$rules = ConvertTo-RabbitMqAlertRules $policy $rabbit
Assert-True ($rules.groups[0].rules.Count -eq 7) 'Expected source, consumer availability, telemetry and enabled DLQ alerts.'
$dlqRules = @($rules.groups[0].rules | Where-Object alert -eq HexagonMessagingDeadLetters)
Assert-True ($dlqRules.Count -eq 1 -and $dlqRules[0].labels.consumer -ceq 'sales-worker') 'Only opted-in DLQs can have DLQ alerts.'
Assert-True ($dlqRules[0].expr.Contains('hexagon-example.dev.sales-worker.dlq')) 'Physical DLQ missing from rule.'

$invalid = Copy-Model $policy
$invalid.consumers[0].replay.enabled = $true
Assert-Rejected { Assert-OperationsPolicy $invalid $rabbit } 'has no DLQ'
$invalid = Copy-Model $policy
$invalid.consumers[1].id = 'worker'
Assert-Rejected { Assert-OperationsPolicy $invalid $rabbit } 'match topology exactly'
$invalid = Copy-Model $policy
$invalid.operatorIdentities.worker = $rabbit.workloadUserNames.'hexagon-example-worker'
Assert-Rejected { Assert-OperationsPolicy $invalid $rabbit } 'application workload identities'
$invalid = Copy-Model $policy
$invalid | Add-Member secret 'forbidden'
Assert-Rejected { Assert-OperationsPolicy $invalid $rabbit } 'Invalid MessagingOperationsPolicy'
$invalid = Copy-Model $policy
$invalid.notificationTargets = @('https://alerts.example.test/hook')
Assert-Rejected { Assert-OperationsPolicy $invalid $rabbit } 'Alertmanager'
$invalid = Copy-Model $policy
$invalid.environment = 'prod'
Assert-Rejected { Assert-OperationsPolicy $invalid $rabbit } 'agree on product'
$invalid = Copy-Model $policy
$invalid.consumers[0].oldestMessageAgeSeconds = 300
Assert-Rejected { Assert-OperationsPolicy $invalid $rabbit } 'oldest-message-age metric'
$invalid = Copy-Model $policy
$invalid.provider = 'unknown-broker'
Assert-Rejected { Assert-OperationsPolicy $invalid $rabbit } 'Invalid MessagingOperationsPolicy'

# WhatIf must not contact GitHub, create a directory, restore an SDK or connect to a broker.
$missing = Join-Path ([IO.Path]::GetTempPath()) ('hexagon-operations-whatif-' + [guid]::NewGuid().ToString('N'))
& (Join-Path $root 'scripts/Export-MessagingOperations.ps1') -Descriptor missing.json -TopologyPolicy missing.json -Policy missing.json -OutputDirectory $missing -WhatIf
Assert-True (-not (Test-Path -LiteralPath $missing)) 'WhatIf wrote generated artifacts.'
Write-Host 'Messaging operations policy checks passed.'
