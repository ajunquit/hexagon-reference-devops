<#
.SYNOPSIS
    Proves the ephemeral identity can read its scopes and is denied persistent/bootstrap scopes.
    Azure probes real endpoints; AWS simulates the federated role's own policies (ADR 0025).
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
if ($inventory.target.ContainsKey('accountId')) {
    # AWS (ADR 0025): the federated role simulates its own permissions; nothing is created or changed.
    Import-Module (Join-Path $PSScriptRoot 'AwsEphemeralEnvironment.psm1')
    function Invoke-IsolationAws([string[]] $Arguments) {
        $result = Invoke-LifecycleCommand aws ($Arguments + @('--region', $inventory.target.region, '--output', 'json')) -TimeoutSeconds 60
        if ($result.exitCode -ne 0) { throw 'lifecycle.ephemeral.isolationTransportFailed' }
        return $result.text | ConvertFrom-Json -AsHashtable -Depth 32
    }
    $caller = Invoke-IsolationAws @('sts', 'get-caller-identity')
    $simulate = {
        param($roleArn, $cases)
        $decisions = @{}
        $directory = Join-Path ([IO.Path]::GetTempPath()) "hexagon-isolation-$([guid]::NewGuid().ToString('N'))"
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        try {
            foreach ($case in $cases) {
                $entries = @($case.context.GetEnumerator() | ForEach-Object { @{ ContextKeyName = $_.Key; ContextKeyValues = @($_.Value); ContextKeyType = 'string' } })
                $requestPath = Join-Path $directory "$($case.id).json"
                [IO.File]::WriteAllText($requestPath, (@{ PolicySourceArn = $roleArn; ActionNames = @($case.action); ResourceArns = @($case.resource); ContextEntries = $entries } | ConvertTo-Json -Depth 8))
                $result = Invoke-IsolationAws @('iam', 'simulate-principal-policy', '--cli-input-json', "file://$requestPath")
                $evaluation = @($result.EvaluationResults)
                if ($evaluation.Count -ne 1) { throw 'lifecycle.ephemeral.isolationNotVerified' }
                $decisions[$case.id] = $evaluation[0].EvalDecision
            }
        }
        finally { Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue }
        return $decisions
    }
    Test-AwsEphemeralIsolation $model $caller.Arn $simulate | ConvertTo-Json -Compress
    return
}
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
