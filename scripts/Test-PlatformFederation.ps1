<#
.SYNOPSIS
    Exercises the current federated environment identity without creating Azure resources.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Definition,
    [Parameter(Mandatory)][ValidateSet('dev', 'staging', 'prod')][string] $Environment
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'PlatformBootstrap.psm1') -Force
$parsed = Read-PlatformBootstrapDefinition $Definition
$settings = $parsed.definition
if (-not $settings.environments.ContainsKey($Environment)) { throw 'Federation diagnostic environment is not configured.' }
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or
    $env:GITHUB_REF -cne 'refs/heads/main' -or $env:GITHUB_REPOSITORY -ine $settings.automation.repository) { throw 'Federation diagnostic requires the trusted main workflow.' }
$accountText = & az account show --output json --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Federated Azure account is unavailable.' }
$account = ($accountText -join "`n") | ConvertFrom-Json
if ($account.id -ine $settings.azure.subscriptionId -or $account.tenantId -ine $settings.azure.tenantId -or $account.user.name -ine $env:AZURE_CLIENT_ID) { throw 'Federated identity target mismatch.' }

function Get-DiagnosticToken([string] $Resource) {
    $text = & az account get-access-token --resource $Resource --subscription $settings.azure.subscriptionId --output json --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Federated token acquisition failed.' }
    return (($text -join "`n") | ConvertFrom-Json).accessToken
}
function Assert-DiagnosticResponse([string] $Uri, [string] $Token, [int] $Expected, [switch] $Storage) {
    $headers = @{ Authorization = "Bearer $Token" }
    if ($Storage) { $headers['x-ms-version'] = '2023-11-03'; $headers['x-ms-date'] = [DateTime]::UtcNow.ToString('R') }
    try { $response = Invoke-WebRequest -Uri $Uri -Headers $headers -Method Get -SkipHttpErrorCheck -TimeoutSec 30 }
    catch { throw 'Federation diagnostic transport failure.' }
    if ([int] $response.StatusCode -ne $Expected) { throw 'Federation diagnostic authorization mismatch.' }
}
$armToken = Get-DiagnosticToken 'https://management.azure.com/'
foreach ($group in $settings.environments[$Environment].resourceGroups) {
    Assert-DiagnosticResponse "https://management.azure.com/subscriptions/$($settings.azure.subscriptionId)/resourcegroups/$group`?api-version=2024-03-01" $armToken 200
}
$storageToken = Get-DiagnosticToken 'https://storage.azure.com/'
$accountUrl = "https://$($settings.state.storageAccount).blob.core.windows.net"
Assert-DiagnosticResponse "$accountUrl/$($settings.state.container)-$Environment`?restype=container&comp=list&maxresults=1" $storageToken 200 -Storage
Assert-DiagnosticResponse "$accountUrl/$($settings.state.container)?restype=container&comp=list&maxresults=1" $storageToken 403 -Storage
foreach ($other in @(Get-BootstrapEnvironments $settings | Where-Object { $_ -cne $Environment })) {
    Assert-DiagnosticResponse "$accountUrl/$($settings.state.container)-$other`?restype=container&comp=list&maxresults=1" $storageToken 403 -Storage
    foreach ($group in $settings.environments[$other].resourceGroups) {
        Assert-DiagnosticResponse "https://management.azure.com/subscriptions/$($settings.azure.subscriptionId)/resourcegroups/$group`?api-version=2024-03-01" $armToken 403
    }
}
# No tokens, raw protocol responses or application state are returned.
@{ environment = $Environment; definitionSha256 = $parsed.sha256; status = 'Verified' } | ConvertTo-Json -Compress
