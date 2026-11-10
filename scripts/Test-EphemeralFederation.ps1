<#
.SYNOPSIS
    Proves the ephemeral identity can read its scopes and is denied persistent/bootstrap scopes.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string] $Definition)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'EphemeralEnvironment.psm1')
Import-Module (Join-Path $PSScriptRoot 'AzureEnvironmentStore.psm1')
Import-Module (Join-Path $PSScriptRoot 'TerraformAzureLifecycle.psm1')
Import-Module (Join-Path $PSScriptRoot 'LifecycleNative.psm1')
$model = Read-EphemeralEnvironment $Definition
$inventory = $model.inventory
Assert-AzureLifecycleRuntime @{ inventory = $inventory }
$context = New-AzureLifecycleContext $inventory
foreach ($root in $inventory.roots) { Get-AzureLifecycleScope $context $root | Out-Null }
function Get-IsolationToken([string] $Resource) {
    $result = Invoke-LifecycleCommand az @('account', 'get-access-token', '--resource', $Resource, '--subscription', $inventory.target.subscriptionId, '--output', 'json', '--only-show-errors') -TimeoutSeconds 45
    if ($result.exitCode -ne 0) { throw 'lifecycle.ephemeral.tokenUnavailable' }
    return ($result.text | ConvertFrom-Json).accessToken
}
function Read-IsolationResponse([string] $Uri, [bool] $Storage) {
    $Token = $(if ($Storage) { $storageToken } else { $armToken })
    $headers = @{ Authorization = "Bearer $Token" }
    if ($Storage) { $headers['x-ms-version'] = '2023-11-03'; $headers['x-ms-date'] = [DateTime]::UtcNow.ToString('R') }
    try { $response = Invoke-WebRequest -Uri $Uri -Method Get -Headers $headers -SkipHttpErrorCheck -TimeoutSec 30 -MaximumRedirection 0 }
    catch { throw 'lifecycle.ephemeral.isolationTransportFailed' }
    return [int] $response.StatusCode
}
$armToken = Get-IsolationToken 'https://management.azure.com/'
$storageToken = Get-IsolationToken 'https://storage.azure.com/'
Test-EphemeralIsolation $model { param($uri, $storage) Read-IsolationResponse $uri $storage } | ConvertTo-Json -Compress
