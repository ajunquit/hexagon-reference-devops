<#
.SYNOPSIS
    Validates, plans, executes or verifies the platform bootstrap.
.DESCRIPTION
    Validate is offline. Plan reads Azure/GitHub metadata unless Offline is supplied.
    Prepare/Apply/Migrate/Verify delegate to the stage runner and require a protected workspace.
    Validate/Plan remain read-only; Output and build caches are local.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][string] $Definition,
    [ValidateSet('Validate', 'Plan', 'Prepare', 'Apply', 'Migrate', 'Verify')][string] $Mode = 'Validate',
    [switch] $Offline,
    [string] $Output,
    [ValidateSet('State', 'Access', 'GitHub')][string] $Stage = 'State',
    [string] $Workspace,
    [string] $ReviewSha256,
    [long] $DiagnosticRunId = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if ($Mode -cin @('Prepare', 'Apply', 'Migrate', 'Verify')) {
    if (-not $Workspace -or $Offline -or $Output) { throw 'Execution modes require Workspace and do not accept Offline or Output.' }
    & (Join-Path $PSScriptRoot 'Invoke-PlatformBootstrapStage.ps1') -Definition $Definition -Mode $Mode -Stage $Stage -Workspace $Workspace -ReviewSha256 $ReviewSha256 -DiagnosticRunId $DiagnosticRunId -WhatIf:$WhatIfPreference
    exit $LASTEXITCODE
}
Import-Module (Join-Path $PSScriptRoot 'PlatformBootstrap.psm1') -Force
$parsed = $null
try {
    $parsed = Read-PlatformBootstrapDefinition -Path $Definition
    if ($Mode -ceq 'Validate') {
        $result = New-PlatformBootstrapResult -Mode Validate -Status Validated -Parsed $parsed -Checks @(@{ code = 'bootstrap.definitionValid'; status = 'Pass' })
    }
    else {
        $observation = $null
        if (-not $Offline) { $observation = Get-PlatformBootstrapObservation -Definition $parsed.definition }
        $result = New-PlatformBootstrapPlan -Parsed $parsed -Observation $observation
    }
}
catch {
    $code = $_.Exception.Message
    if ($code -cnotmatch '^bootstrap[.][A-Za-z0-9.]+$') { $code = 'bootstrap.preflightFailed' }
    $invalidDefinition = $code -in @('bootstrap.definitionInvalid', 'bootstrap.productMismatch', 'bootstrap.targetInvalid', 'bootstrap.identityShared', 'bootstrap.resourceGroupShared', 'bootstrap.reviewerDuplicate')
    $result = New-PlatformBootstrapResult -Mode $Mode -Status $(if ($invalidDefinition) { 'Invalid' } else { 'Blocked' }) -Parsed $parsed -Checks @(@{ code = $code; status = 'Blocked' })
}
if ($Output -and $WhatIfPreference) { $result.checks += @{ code = 'bootstrap.outputSkipped'; status = 'Pass' } }
$json = ConvertTo-PlatformBootstrapJson $result
$resultSchema = Join-Path (Split-Path -Parent $PSScriptRoot) 'contracts/schemas/platform-bootstrap-result-v1.schema.json'
if (-not ($json | Test-Json -SchemaFile $resultSchema -ErrorAction SilentlyContinue)) { throw 'Invalid bootstrap result.' }
if ($Output -and -not $WhatIfPreference -and $PSCmdlet.ShouldProcess($Output, 'Write bootstrap result JSON')) {
    $path = [IO.Path]::GetFullPath($Output)
    if (Test-Path -LiteralPath $path) { throw 'Bootstrap output already exists.' }
    if ($path -eq [IO.Path]::GetFullPath($Definition)) { throw 'Bootstrap output cannot replace its definition.' }
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json + "`n")
        $stream.Write($bytes)
    }
    finally { $stream.Dispose() }
}
$json
if ($result.status -in @('Invalid', 'Blocked')) { exit 1 }
if ($result.status -ceq 'Unverified') { exit 2 }
exit 0
