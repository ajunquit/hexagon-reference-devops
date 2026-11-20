<#
.SYNOPSIS
    Checks the Azure operations policy: principal identities and notification targets.
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
$azure = Get-Content -Raw (Join-Path $root 'examples/azure-service-bus-policy.json') | ConvertFrom-Json
$azurePolicy = Get-Content -Raw (Join-Path $root 'examples/messaging-operations-policy.json') | ConvertFrom-Json
$azurePolicy.provider = 'azure-service-bus'
$azurePolicy.notificationTargets = @('/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-example/providers/Microsoft.Insights/actionGroups/example')
$azurePolicy.operatorIdentities.worker = '00000000-0000-0000-0000-000000000011'
$azurePolicy.operatorIdentities.'sales-worker' = '00000000-0000-0000-0000-000000000012'
$azurePolicy.consumers[0].deadLetterThreshold = 1
$azurePolicy.consumers[0].quarantineReviewHours = 24
Assert-OperationsPolicy $azurePolicy $azure
$invalid = Copy-Model $azurePolicy
$invalid.operatorIdentities.worker = 'invalid-principal'
Assert-Rejected { Assert-OperationsPolicy $invalid $azure } 'principal UUIDs'

Write-Host 'Azure messaging operations policy checks passed.'
