<#
.SYNOPSIS
    Validates operations policy against the provider topology without touching a broker.
#>
[CmdletBinding()]
param([Parameter(Mandatory)] [string] $Policy, [Parameter(Mandatory)] [string] $TopologyPolicy)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MessagingOperations.psm1') -Force
$operations = Get-Content -Raw -LiteralPath $Policy | ConvertFrom-Json
$topology = Get-Content -Raw -LiteralPath $TopologyPolicy | ConvertFrom-Json
$validator = "Test-$(Invoke-OperationsProvider (Get-OperationsProviderModule $operations.provider) Get-OperationsContracts)Policy.ps1"
& (Join-Path $PSScriptRoot $validator) -Policy $TopologyPolicy
Assert-OperationsPolicy -Operations $operations -Topology $topology
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$relative = [IO.Path]::GetRelativePath($root, (Resolve-Path -LiteralPath $Policy).Path).Replace('\', '/')
if ($relative.StartsWith('products/', [StringComparison]::Ordinal) -and
    $relative -cne "products/$($operations.product)/environments/$($operations.environment)/messaging-operations-policy.json") {
    throw 'Operations policy location must match its declared product and environment.'
}
Write-Host 'Validated messaging operations policy.'
