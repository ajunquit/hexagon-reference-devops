<#
.SYNOPSIS
    Exercises valid and invalid phase 3 application contract descriptors.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$validator = Join-Path $repositoryRoot 'scripts/Test-ProductEnvironmentDescriptor.ps1'
$generator = Join-Path $repositoryRoot 'scripts/New-ProductEnvironmentDescriptor.ps1'
$examplePath = Join-Path $repositoryRoot 'examples/product-environment.json'
$temporaryRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "hexagon-devops-contract-tests-$([guid]::NewGuid().ToString('N'))"

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock] $Action,

        [Parameter(Mandatory = $true)]
        [string] $ExpectedMessage
    )

    $failedAsExpected = $false
    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message -notlike "*$ExpectedMessage*") {
            throw "Expected an error containing '$ExpectedMessage', got: $($_.Exception.Message)"
        }
        $failedAsExpected = $true
    }

    if (-not $failedAsExpected) {
        throw "Expected an error containing '$ExpectedMessage', but the action succeeded."
    }
}

[IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
try {
    & $validator -Descriptor $examplePath

    $unknownPropertyPath = Join-Path $temporaryRoot 'unknown-property.json'
    $unknownProperty = Get-Content -Raw $examplePath | ConvertFrom-Json
    $unknownProperty | Add-Member -NotePropertyName 'physicalQueue' -NotePropertyValue 'forbidden'
    [IO.File]::WriteAllText(
        $unknownPropertyPath,
        ($unknownProperty | ConvertTo-Json -Depth 8) + "`n",
        [Text.UTF8Encoding]::new($false)
    )
    Assert-Throws `
        -Action { & $validator -Descriptor $unknownPropertyPath } `
        -ExpectedMessage 'does not satisfy ProductEnvironment v1'

    $duplicateComponentPath = Join-Path $temporaryRoot 'duplicate-component.json'
    $duplicateComponent = Get-Content -Raw $examplePath | ConvertFrom-Json
    $copy = $duplicateComponent.components[0] | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $duplicateComponent.components = @($duplicateComponent.components) + @($copy)
    [IO.File]::WriteAllText(
        $duplicateComponentPath,
        ($duplicateComponent | ConvertTo-Json -Depth 8) + "`n",
        [Text.UTF8Encoding]::new($false)
    )
    Assert-Throws `
        -Action { & $validator -Descriptor $duplicateComponentPath } `
        -ExpectedMessage 'Duplicate component names'

    Assert-Throws `
        -Action {
            & $generator `
                -Product 'hexagon-example' `
                -Environment 'dev' `
                -BackendRepository 'ajunquit/example'
        } `
        -ExpectedMessage 'BackendRepository and BackendRef must be provided together'

    Assert-Throws -Action {
        & $generator -Product hexagon-example -Environment dev -BackendRepository invalid/not-requested -BackendRef main -IncludeAcceptance -WhatIf
    } -ExpectedMessage 'IncludeAcceptance requires IncludeBackendHosting for a backend component'

    & $generator -Product hexagon-example -Environment dev -BackendRepository invalid/not-requested -BackendRef main `
        -FrontendRepository invalid/not-requested -FrontendRef main -IncludeBackendHosting -IncludeAcceptance -WhatIf

    & $generator `
        -Product 'hexagon-example' `
        -Environment 'dev' `
        -BackendRepository 'invalid/not-requested' `
        -BackendRef 'main' `
        -WhatIf
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

Write-Host 'Application contract tests passed.'
