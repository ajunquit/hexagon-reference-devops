<#
.SYNOPSIS
    Validates the exact selected inventory and reports dependency order without cloud access.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Inventory,
    [Parameter(Mandatory)][ValidateSet('dev', 'staging', 'prod')][string] $Environment,
    [Parameter(Mandatory)][string] $InstanceId,
    [ValidateSet('Create', 'Destroy')][string] $Operation = 'Create'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'EnvironmentLifecycle.psm1') -Force
try {
    $model = Read-EnvironmentInventory $Inventory
    $product = (Get-Content -Raw -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) '.config/product.json') | ConvertFrom-Json).product
    if ($model.product -cne $product -or $model.environment -cne $Environment -or $model.instance.id -cne $InstanceId) { throw 'lifecycle.selectionMismatch' }
    @{ apiVersion = 'hexagon.ec/environment-inventory-check/v1'; status = 'Validated'; applicationVerified = $false
        inventorySha256 = Get-LifecycleFileHash $Inventory; operation = $Operation; order = @(Get-EnvironmentRootOrder $model $Operation) } | ConvertTo-Json -Depth 8
}
catch {
    $code = $_.Exception.Message
    if ($code -cnotmatch '^lifecycle[.][A-Za-z0-9.]+$') { $code = 'lifecycle.validationFailed' }
    @{ apiVersion = 'hexagon.ec/environment-inventory-check/v1'; status = 'Blocked'; applicationVerified = $false; code = $code } | ConvertTo-Json
    exit 1
}
