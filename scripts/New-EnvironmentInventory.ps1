<#
.SYNOPSIS
    Creates a new private lifecycle inventory from a validated initial definition, without cloud access.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][string] $Definition,
    [Parameter(Mandatory)][ValidateSet('dev', 'staging', 'prod')][string] $Environment,
    [Parameter(Mandatory)][string] $InstanceId,
    [Parameter(Mandatory)][string] $Output
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'EnvironmentLifecycle.psm1') -Force
try {
    $model = Read-EnvironmentInventory $Definition
    $repository = Split-Path -Parent $PSScriptRoot
    $product = (Get-Content -Raw -LiteralPath (Join-Path $repository '.config/product.json') | ConvertFrom-Json).product
    if ($model.product -cne $product -or $model.environment -cne $Environment -or $model.instance.id -cne $InstanceId) { throw 'lifecycle.selectionMismatch' }
    $path = [IO.Path]::GetFullPath($Output, (Get-Location).ProviderPath)
    $prefix = [IO.Path]::GetFullPath((Join-Path $repository 'artifacts')) + [IO.Path]::DirectorySeparatorChar
    $comparison = $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal })
    if (-not $path.StartsWith($prefix, $comparison)) { throw 'lifecycle.outputOutsideArtifacts' }
    $hash = $null; $status = 'Unverified'
    if (-not $WhatIfPreference -and $PSCmdlet.ShouldProcess($path, 'Create lifecycle inventory')) {
        $hash = New-EnvironmentInventory $model $path -Confirm:$false; $status = 'InventoryCreated'
    }
    @{ apiVersion = 'hexagon.ec/environment-inventory-check/v1'; status = $status; applicationVerified = $false; inventorySha256 = $hash } | ConvertTo-Json
    if ($status -ceq 'Unverified') { exit 2 }
}
catch {
    $code = $_.Exception.Message
    if ($code -cnotmatch '^lifecycle[.][A-Za-z0-9.]+$') { $code = 'lifecycle.inventoryCreationFailed' }
    @{ apiVersion = 'hexagon.ec/environment-inventory-check/v1'; status = 'Blocked'; applicationVerified = $false; code = $code } | ConvertTo-Json
    exit 1
}
