<#
.SYNOPSIS
    Starts one real local messaging provider, verifies readiness through the start script, and stops it.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('azure-service-bus', 'aws-sns-sqs', 'rabbitmq')]
    [string] $Provider,

    [switch] $AcceptLicense,

    [switch] $UseExamplePolicy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$backendRoot = Join-Path $PSScriptRoot 'fixtures/backend'
$temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$probeRoot = Join-Path $temporaryParent (
    'hexagon-local-messaging-runtime-' + [guid]::NewGuid().ToString('N')
)
$attemptedStart = $false

try {
    New-Item -ItemType Directory -Path (Join-Path $probeRoot '.hexagon/schemas') -Force | Out-Null
    Copy-Item `
        -LiteralPath (Join-Path $backendRoot '.hexagon/schemas/messaging-requirements-v1.schema.json') `
        -Destination (Join-Path $probeRoot '.hexagon/schemas/messaging-requirements-v1.schema.json')
    $manifest = Get-Content -Raw -LiteralPath `
        (Join-Path $backendRoot '.hexagon/messaging-requirements.json') | ConvertFrom-Json
    $manifest.provider = $Provider
    [IO.File]::WriteAllText(
        (Join-Path $probeRoot '.hexagon/messaging-requirements.json'),
        (($manifest | ConvertTo-Json -Depth 20) + "`n"),
        [Text.UTF8Encoding]::new($false)
    )

    $startArguments = @{ BackendPath = $probeRoot }
    if ($UseExamplePolicy) {
        $exampleName = switch ($Provider) {
            'azure-service-bus' { 'azure-service-bus-policy.json' }
            'aws-sns-sqs' { 'aws-sns-sqs-policy.json' }
            'rabbitmq' { 'rabbitmq-policy.json' }
        }
        $policyPath = Join-Path $probeRoot $exampleName
        $policyText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot "examples/$exampleName")
        if ($Provider -ceq 'azure-service-bus') {
            # The cloud example exceeds the emulator's documented one-hour TTL limit.
            $localPolicy = $policyText | ConvertFrom-Json
            foreach ($entity in @($localPolicy.destinations) + @($localPolicy.consumers)) { $entity.defaultMessageTtl = 'PT1H' }
            foreach ($destination in $localPolicy.destinations) { $destination.duplicateDetectionHistory = 'PT5M' }
            $policyText = $localPolicy | ConvertTo-Json -Depth 20
        }
        [IO.File]::WriteAllText($policyPath, $policyText, [Text.UTF8Encoding]::new($false))
        $startArguments.Policy = $policyPath
    }
    if ($AcceptLicense) { $startArguments.AcceptLicense = $true }
    $attemptedStart = $true
    & (Join-Path $repositoryRoot 'scripts/Start-LocalMessaging.ps1') @startArguments
}
finally {
    try {
        if ($attemptedStart) {
            & (Join-Path $repositoryRoot 'scripts/Stop-LocalMessaging.ps1') -BackendPath $probeRoot
        }
    }
    finally {
        $resolvedProbeRoot = [IO.Path]::GetFullPath($probeRoot)
        $expectedPrefix = Join-Path $temporaryParent 'hexagon-local-messaging-runtime-'
        if ($resolvedProbeRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $resolvedProbeRoot)) {
            Remove-Item -LiteralPath $resolvedProbeRoot -Recurse -Force
        }
    }
}

Write-Host "Local messaging runtime check passed: $Provider"
