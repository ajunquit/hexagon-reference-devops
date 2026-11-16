<#
.SYNOPSIS
    Validates, plans, prepares or verifies Keycloak OIDC/UMA bindings without deploying infrastructure.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param([Parameter(Mandatory)][string] $Configuration,
    [ValidateSet('Validate', 'Plan', 'Apply', 'Verify')][string] $Mode = 'Plan')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'KeycloakAuthorization.psm1') -Force
$model = Read-KeycloakAuthorization $Configuration
if ($Mode -eq 'Validate') { Get-KeycloakAuthorizationBindings $model; return }
if ($WhatIfPreference) { Get-KeycloakAuthorizationBindings $model; $null = $PSCmdlet.ShouldProcess($model.authority, 'Prepare Keycloak OIDC and delegated UMA administration'); return }
$context = New-KeycloakAuthorizationContext $model
try {
    if ($Mode -eq 'Apply') {
        if ($PSCmdlet.ShouldProcess($model.authority, 'Prepare Keycloak OIDC and delegated UMA administration')) {
            Invoke-KeycloakAuthorizationPreparation $context
        }
    } elseif ($Mode -eq 'Verify') { Test-KeycloakAuthorizationPreparation $context }
    else { Get-KeycloakAuthorizationPlan $context }
} finally { $context.client.Dispose(); $context.handler.Dispose(); $context.token = $null }
