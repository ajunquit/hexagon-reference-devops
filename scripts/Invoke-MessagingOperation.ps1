<#
.SYNOPSIS
    Inspects metadata or explicitly replays one bounded DLQ batch; credentials only come from the environment.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)] [ValidateSet('Plan', 'Inspect', 'Replay')] [string] $Action,
    [Parameter(Mandatory)] [string] $Target,
    [Parameter(Mandatory)] [string] $Product,
    [Parameter(Mandatory)] [ValidateSet('dev', 'staging', 'prod')] [string] $Environment,
    [Parameter(Mandatory)] [string] $Consumer,
    [ValidateRange(1, 100)] [int] $Limit = 1,
    [guid] $Incident = [guid]::Empty,
    [switch] $Local,
    [switch] $Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$targetPath = (Resolve-Path -LiteralPath $Target).Path
$model = Get-Content -Raw -LiteralPath $targetPath | ConvertFrom-Json
if ($model.product -cne $Product -or $model.environment -cne $Environment -or $model.consumer -cne $Consumer) {
    throw 'Explicit product, environment and consumer must match the operation target.'
}
if ($Limit -gt $model.maxBatchSize) { throw 'Limit exceeds the per-consumer replay policy.' }
if ($Action -eq 'Replay' -and (-not $model.replayEnabled -or $Incident -eq [guid]::Empty)) {
    throw 'Replay requires an enabled policy and an opaque incident UUID.'
}
if ($Local -and $Environment -cne 'dev') { throw 'Local connections are restricted to dev.' }
$effectiveAction = if ($Action -eq 'Replay' -and -not $Execute) { 'plan' } else { $Action.ToLowerInvariant() }
if (-not $PSCmdlet.ShouldProcess("$Product/$Environment/$Consumer", "$effectiveAction up to $Limit messages")) { return }
$project = Join-Path $PSScriptRoot '../operations/Hexagon.Messaging.Operations/Hexagon.Messaging.Operations.csproj'
$arguments = @($effectiveAction, $targetPath, '--product', $Product, '--environment', $Environment, '--consumer', $Consumer, '--limit', "$Limit")
if ($Incident -ne [guid]::Empty) { $arguments += @('--incident', $Incident.ToString()) }
if ($Local) { $arguments += '--local' }
& dotnet run --project $project --no-launch-profile -- @arguments
if ($LASTEXITCODE -ne 0) { throw 'Messaging operation failed. Review the sanitized audit output; no automatic retry was performed.' }
