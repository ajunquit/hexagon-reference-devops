<#
.SYNOPSIS
    Verifies release integrity, contract composition and public static-site bindings offline.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts/HostingContracts.psm1') -Force
Import-Module (Join-Path $root 'scripts/StaticWebConfiguration.psm1') -Force
function Assert-Rejected([scriptblock] $Action, [string] $Expected) {
    try { & $Action } catch {
        if ($_.Exception.Message -notlike "*$Expected*") { throw }
        return
    }
    throw "Expected rejection: $Expected"
}
$descriptorPath = Join-Path $root 'examples/hosting-product-environment.json'
$releasePath = Join-Path $root 'examples/application-release.json'
& (Join-Path $root 'scripts/Test-ApplicationRelease.ps1') -Descriptor $descriptorPath -Release $releasePath
$descriptor = Get-Content -Raw $descriptorPath | ConvertFrom-Json -AsHashtable
$release = Read-HostingContract -Path $releasePath -Schema 'application-release-v1'
$policy = Read-HostingContract -Path (Join-Path $root 'examples/azure-hosting-policy.json') -Schema 'azure-hosting-policy-v1'
$backend = Get-Content -Raw (Join-Path $PSScriptRoot 'fixtures/hosting/backend.json') | ConvertFrom-Json -AsHashtable
$frontend = Get-Content -Raw (Join-Path $PSScriptRoot 'fixtures/hosting/frontend.json') | ConvertFrom-Json -AsHashtable
$inputs = ConvertTo-AzureHostingInput $descriptor $release $policy $backend $frontend
if ($inputs.workloads.Count -ne 3 -or $inputs.application_rollout_enabled -or $inputs.maintenance_jobs_enabled -or $inputs.auth.audience -cne $backend.identity.audience) { throw 'Invalid materialized hosting bindings.' }
$policy.infrastructure.registry_name = 'exampletarget0001'
$promoted = ConvertTo-AzureHostingInput $descriptor $release $policy $backend $frontend
if ($promoted.workloads['hexagon-example-api'].image -cne ('exampletarget0001.azurecr.io/hexagon-example-api@sha256:' + ('d' * 64))) { throw 'Promotion must preserve repository and digest when changing registry.' }
$policy = Read-HostingContract -Path (Join-Path $root 'examples/azure-hosting-policy.json') -Schema 'azure-hosting-policy-v1'
$release.sources[0].commit = '9' * 40
Assert-Rejected { Assert-ReleaseSources $descriptor $release } 'sources do not match'
$release = Read-HostingContract -Path $releasePath -Schema 'application-release-v1'
$release.sources[0].manifests[0].sha256 = '9' * 64
Assert-Rejected { Assert-ReleaseSources $descriptor $release } 'checksums do not match'
$release = Read-HostingContract -Path $releasePath -Schema 'application-release-v1'
$release.artifacts.backend.Remove('hexagon-example-worker')
Assert-Rejected { ConvertTo-AzureHostingInput $descriptor $release $policy $backend $frontend } 'exactly match'
$outputs = @{
    api_url = @{ value = 'https://api.example.test/api/v1' }
    frontend_authentication = @{ value = @{ authority = 'https://auth.example.test/realms/hexagon'; clientId = 'example-web'; scope = 'openid profile email example_api.all'; clientSecret = 'must-not-be-exported' } }
    unrelated_secret = @{ sensitive = $true; value = 'must-not-be-exported' }
}
$public = ConvertTo-StaticWebConfiguration -Manifest $frontend -Outputs $outputs
$json = $public | ConvertTo-Json -Depth 15
if ($json.Contains('must-not-be-exported') -or $public['runtime-config.json'].Count -ne 2) { throw 'Unexpected public configuration.' }
$site = $public['staticwebapp.config.json']
if ($site.navigationFallback.rewrite -cne '/index.html' -or '/runtime-config.json' -cnotin $site.navigationFallback.exclude -or $site.routes[0].headers['Cache-Control'] -cne 'no-store') { throw 'Unsafe SPA routing or cache configuration.' }
$outputs.api_url.value = $null
Assert-Rejected { ConvertTo-StaticWebConfiguration -Manifest $frontend -Outputs $outputs } 'HTTPS /api/v1'
$outputs.api_url.value = 'https://api.example.test/api/v1'
$outputs.frontend_authentication.value.authority = 'http://auth.example.test/realms/hexagon'
Assert-Rejected { ConvertTo-StaticWebConfiguration -Manifest $frontend -Outputs $outputs } 'HTTPS authority'
& (Join-Path $root 'scripts/Export-AzureHostingInputs.ps1') -Descriptor 'unused' -Release 'unused' -Policy 'unused' -Output (Join-Path ([IO.Path]::GetTempPath()) 'unused.auto.tfvars.json') -WhatIf
Write-Host 'Hosting contract and public configuration tests passed.'
