<#
.SYNOPSIS
    Proves the ephemeral identity can read its scopes and is denied persistent/bootstrap scopes.
    The cloud of the target runs its own diagnostic (EphemeralEnvironment.psm1).
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string] $Definition)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'EphemeralEnvironment.psm1')
$model = Read-EphemeralEnvironment $Definition
Invoke-EphemeralCloud (Get-EphemeralCloud $model.inventory.target) Test-EphemeralCloudFederation @(, $model) | ConvertTo-Json -Compress
