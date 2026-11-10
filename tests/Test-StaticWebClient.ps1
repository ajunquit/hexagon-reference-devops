<#
.SYNOPSIS
    Starts the real pinned client with a deliberately invalid action, without credentials or uploads.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/StaticWebClient.psm1')
Import-Module (Join-Path $PSScriptRoot '../scripts/LifecycleNative.psm1')
Get-StaticWebClientPath | Out-Null
$directory = Join-Path $PSScriptRoot '../artifacts'
$result = Invoke-LifecycleCommand static-web-client @() $directory -Environment @{ DEPLOYMENT_ACTION = 'verify-client'; DEPLOYMENT_PROVIDER = 'SwaCli'; VERBOSE = 'false'; DEPLOYMENT_TOKEN = '' } -TimeoutSeconds 30
if ($result.exitCode -ne 1 -or -not $result.text.Contains('Unrecognized deployment_action: verify-client')) { throw 'The pinned content client did not start or did not reject the non-deploying probe.' }
foreach ($case in @(@{ arguments = @('forbidden'); environment = @{}; code = 'clientArgumentsForbidden' }, @{ arguments = @(); environment = @{ GITHUB_TOKEN = 'forbidden' }; code = 'clientEnvironmentForbidden' })) {
    try { Invoke-LifecycleCommand static-web-client $case.arguments $directory -Environment $case.environment -TimeoutSeconds 5 | Out-Null }
    catch { if ($_.Exception.Message.Contains($case.code)) { continue }; throw }
    throw 'Native content client accepted an untrusted argument or environment key.'
}
Write-Host 'Pinned content deployment client started and rejected an invalid action; no Azure credentials or upload used.'
