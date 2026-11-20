Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$backendRoot = Join-Path $PSScriptRoot 'fixtures/backend'
Import-Module (Join-Path $repositoryRoot 'scripts/ContractSchemas.psm1')

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

$temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $temporaryParent ("hexagon-local-messaging-" + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    # One fixture per provider of the repository: each template brings those of its cloud.
    $fixtures = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'fixtures/local-messaging') -Filter '*.ps1' -File | Sort-Object Name)
    if ($fixtures.Count -eq 0) { throw 'No local messaging fixture.' }
    foreach ($fixture in $fixtures) {
        $provider = $fixture.BaseName
        $checks = & $fixture.FullName
        $probeBackend = Join-Path $testRoot "backend-$provider"
        New-Item -ItemType Directory -Path (Join-Path $probeBackend '.hexagon/schemas') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $backendRoot '.hexagon/schemas/messaging-requirements-v1.schema.json') `
            -Destination (Join-Path $probeBackend '.hexagon/schemas/messaging-requirements-v1.schema.json')
        $manifest = Get-Content -Raw -LiteralPath `
            (Join-Path $backendRoot '.hexagon/messaging-requirements.json') | ConvertFrom-Json
        $manifest.provider = $provider
        [IO.File]::WriteAllText(
            (Join-Path $probeBackend '.hexagon/messaging-requirements.json'),
            (($manifest | ConvertTo-Json -Depth 20) + "`n"),
            [Text.UTF8Encoding]::new($false)
        )

        $output = Join-Path $testRoot "generated-$provider"
        $bindings = Join-Path $testRoot "bindings-$provider.json"
        & (Join-Path $repositoryRoot 'scripts/New-LocalMessaging.ps1') `
            -BackendPath $probeBackend `
            -OutputDirectory $output `
            -BindingsOutput $bindings
        Assert-True (Test-Path -LiteralPath (Join-Path $output 'compose.yaml')) `
            "Compose file is missing for $provider."
        $bindingJson = Get-Content -Raw -LiteralPath $bindings
        Assert-True (Test-ContractJson $bindingJson local-messaging-bindings-v1) `
            "Bindings are invalid for $provider."
        $bindingModel = $bindingJson | ConvertFrom-Json
        Assert-True ([string] $bindingModel.provider -ceq $provider) `
            "Bindings selected the wrong provider for $provider."
        Assert-True (@($bindingModel.workloads.PSObject.Properties).Count -eq 3) `
            "Bindings do not cover every workload for $provider."

        & $checks.Default $output

        $exampleName = "$provider-policy.json"
        $policyPath = Join-Path $testRoot "policy-$provider.json"
        $policyText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot "examples/$exampleName")
        [IO.File]::WriteAllText($policyPath, $policyText, [Text.UTF8Encoding]::new($false))
        $policyOutput = Join-Path $testRoot "generated-policy-$provider"
        & $checks.PreparePolicy $policyPath $policyText $probeBackend $policyOutput $testRoot
        & (Join-Path $repositoryRoot 'scripts/New-LocalMessaging.ps1') `
            -BackendPath $probeBackend `
            -Policy $policyPath `
            -OutputDirectory $policyOutput `
            -BindingsOutput (Join-Path $testRoot "bindings-policy-$provider.json")


        & $checks.Policy $policyOutput
    }
}
finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $expectedPrefix = Join-Path $temporaryParent 'hexagon-local-messaging-'
    if ($resolvedTestRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedTestRoot)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}

Write-Host 'Local messaging generation checks passed for all providers.'
