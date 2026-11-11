<#
.SYNOPSIS
    Exercises the diagnostic script against account/token and HTTP doubles without requesting tokens.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$previous = @{}
foreach ($name in @('GITHUB_ACTIONS', 'GITHUB_EVENT_NAME', 'GITHUB_REF', 'GITHUB_REPOSITORY', 'AZURE_CLIENT_ID')) {
    $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$global:hexagonFederationProbeStatus = 403
$global:hexagonFederationProduct = (Get-Content -Raw (Join-Path $root '.config/product.json') | ConvertFrom-Json).product
$fixture = Join-Path ([IO.Path]::GetTempPath()) "hexagon-federation-$([guid]::NewGuid().ToString('N')).yaml"
[IO.File]::WriteAllText($fixture, (Get-Content -Raw (Join-Path $root 'examples/platform-bootstrap.yaml')).Replace('hexagon-template', $global:hexagonFederationProduct))
$global:hexagonFederationProbeCalls = [Collections.Generic.List[string]]::new()
function global:az {
    $global:LASTEXITCODE = 0
    if ($args[0] -cne 'account') { throw 'Diagnostic attempted an unexpected Azure command.' }
    if ($args[1] -ceq 'show') {
        return '{"id":"22222222-2222-2222-2222-222222222222","tenantId":"11111111-1111-1111-1111-111111111111","user":{"name":"dev-client"}}'
    }
    if ($args[1] -ceq 'get-access-token') { return '{"accessToken":"never-log-this-token"}' }
    throw 'Diagnostic attempted an unexpected account command.'
}
function global:Invoke-WebRequest {
    param($Uri, $Headers, $Method, [switch] $SkipHttpErrorCheck, $TimeoutSec)
    if ($Method -cne 'Get' -or -not $SkipHttpErrorCheck -or $TimeoutSec -ne 30 -or $Headers.Authorization -cne 'Bearer never-log-this-token') { throw 'Unexpected diagnostic HTTP request.' }
    $global:hexagonFederationProbeCalls.Add($Uri)
    $own = $Uri -match ('^https://management[.]azure[.]com/.*/resourcegroups/rg-' + [regex]::Escape($global:hexagonFederationProduct) + '-dev(?:-|[?])') -or $Uri -match '^https://sthexagontemplatestate[.]blob[.]core[.]windows[.]net/tfstate-dev[?]'
    return @{ StatusCode = $(if ($own) { 200 } else { $global:hexagonFederationProbeStatus }) }
}
try {
    [Environment]::SetEnvironmentVariable('GITHUB_ACTIONS', 'true', 'Process')
    [Environment]::SetEnvironmentVariable('GITHUB_EVENT_NAME', 'workflow_dispatch', 'Process')
    [Environment]::SetEnvironmentVariable('GITHUB_REF', 'refs/heads/main', 'Process')
    [Environment]::SetEnvironmentVariable('GITHUB_REPOSITORY', "example-owner/$($global:hexagonFederationProduct)-devops", 'Process')
    [Environment]::SetEnvironmentVariable('AZURE_CLIENT_ID', 'dev-client', 'Process')
    $command = Join-Path $root 'scripts/Test-PlatformFederation.ps1'
    $definition = $fixture
    $json = & $command -Definition $definition -Environment dev
    if (($json | ConvertFrom-Json).status -cne 'Verified' -or $json -match 'never-log-this-token' -or $global:hexagonFederationProbeCalls.Count -ne 10) { throw 'Diagnostic did not prove the expected isolation checks or disclosed a token.' }
    foreach ($status in @(404, 200, 401, 500)) {
        $global:hexagonFederationProbeStatus = $status
        $rejected = $false
        try { & $command -Definition $definition -Environment dev | Out-Null }
        catch { if ($_.Exception.Message -cne 'Federation diagnostic authorization mismatch.') { throw }; $rejected = $true }
        if (-not $rejected) { throw "Diagnostic accepted unexpected cross-environment response: $status" }
    }
    [Environment]::SetEnvironmentVariable('GITHUB_REF', 'refs/heads/unsafe', 'Process')
    $global:hexagonFederationProbeCalls.Clear()
    $rejected = $false
    try { & $command -Definition $definition -Environment dev | Out-Null }
    catch { if ($_.Exception.Message -cne 'Federation diagnostic requires the trusted main workflow.') { throw }; $rejected = $true }
    if (-not $rejected -or $global:hexagonFederationProbeCalls.Count -ne 0) { throw 'Untrusted branch reached the authorization probes.' }
}
finally {
    foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
    Remove-Item Function:az, Function:Invoke-WebRequest
    Remove-Variable -Name hexagonFederationProbeStatus, hexagonFederationProbeCalls, hexagonFederationProduct -Scope Global
    Remove-Item -LiteralPath $fixture -Force
}
Write-Host 'Federation protocol tests passed: exact 403, wrong status codes, main boundary and token redaction.'
