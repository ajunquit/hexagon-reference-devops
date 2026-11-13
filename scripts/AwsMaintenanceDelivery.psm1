Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TerraformAwsLifecycle.psm1')
Import-Module (Join-Path $PSScriptRoot 'AwsEnvironmentStore.psm1')
Import-Module (Join-Path $PSScriptRoot 'PlatformBootstrap.psm1')

# Runs one maintenance task of the instance with ecs:RunTask (ADR 0024 order), with the guarantees of the
# Azure jobs: a durable intent precedes the non-idempotent RunTask, the task carries the attempt as
# --started-by so that a lost response is reconciled instead of repeated, and only the expected task
# definition counts. A failed execution stops the delivery for investigation.

function Get-AwsDeliveryTaskHash([hashtable] $Expected) {
    return Get-AwsLifecycleBytesHash ([Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson $Expected)))
}

function Get-AwsDeliveryTaskStatus([hashtable] $Task, [hashtable] $Expected, [string] $AttemptId) {
    if ($Task.taskDefinitionArn -cne $Expected.taskDefinitionArn -or $Task.startedBy -cne $AttemptId -or $Task.clusterArn -cnotmatch "/$([regex]::Escape($Expected.cluster))$") { throw 'lifecycle.delivery.executionChanged' }
    if ($Task.lastStatus -cne 'STOPPED') { return 'Running' }
    $container = @($Task.containers | Where-Object name -CEQ 'maintenance')
    if ($container.Count -ne 1) { throw 'lifecycle.delivery.executionChanged' }
    $succeeded = $Task.stopCode -ceq 'EssentialContainerExited' -and $container[0].ContainsKey('exitCode') -and $container[0].exitCode -eq 0
    return $(if ($succeeded) { 'Succeeded' } else { 'Failed' })
}

function Invoke-AwsDeliveryMaintenance {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context, [string] $TaskId, [hashtable] $Expected, [hashtable] $Record,
        [Parameter(Mandatory)][scriptblock] $Persist, [int] $TimeoutSeconds = 1900, [int] $PollSeconds = 10)
    if (-not $PSCmdlet.ShouldProcess($TaskId, 'Run or reconcile the recorded maintenance task')) { return }
    Assert-AwsLifecycleLease $Context -Confirm:$false
    $hash = Get-AwsDeliveryTaskHash $Expected
    if ($null -ne $Record -and ($Record.jobId -cne $Expected.taskDefinitionArn -or $Record.templateSha256 -cne $hash)) { throw 'lifecycle.delivery.jobEvidenceStale' }
    if ($null -ne $Record -and $Record.status -ceq 'Failed') { throw 'lifecycle.delivery.failedExecutionRequiresInvestigation' }
    if ($null -ne $Record -and $Record.status -ceq 'Succeeded') { return $Record }
    if ($null -eq $Record) {
        $Record = @{ jobId = $Expected.taskDefinitionArn; attemptId = [guid]::NewGuid().ToString(); templateSha256 = $hash; executionId = $null; status = 'Starting' }
        & $Persist $Record | Out-Null
        $network = "awsvpcConfiguration={subnets=[$($Expected.subnets -join ',')],securityGroups=[$($Expected.securityGroups -join ',')],assignPublicIp=ENABLED}"
        $started = Invoke-AwsLifecycleCli $Context @('ecs', 'run-task', '--cluster', $Expected.cluster, '--task-definition', $Expected.taskDefinitionArn,
            '--launch-type', 'FARGATE', '--count', '1', '--started-by', $Record.attemptId, '--network-configuration', $network)
        if ($started.exitCode -ne 0) { throw 'lifecycle.delivery.jobStartUncertain' }
        $response = $started.text | ConvertFrom-Json -AsHashtable -Depth 16
        if (@($response.failures).Count -gt 0 -or @($response.tasks).Count -ne 1) { throw 'lifecycle.delivery.jobStartRejected' }
        $Record.executionId = [string] $response.tasks[0].taskArn; $Record.status = 'Running'
        & $Persist $Record | Out-Null
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        Assert-AwsLifecycleLease $Context -Confirm:$false
        if (-not $Record.executionId) {
            # A lost RunTask response: adopt the one task that carries this attempt, never start another.
            $found = @()
            foreach ($status in @('RUNNING', 'STOPPED')) {
                $listed = Invoke-AwsLifecycleCli $Context @('ecs', 'list-tasks', '--cluster', $Expected.cluster, '--started-by', $Record.attemptId, '--desired-status', $status)
                if ($listed.exitCode -ne 0) { throw 'lifecycle.delivery.executionUnavailable' }
                $found += @(($listed.text | ConvertFrom-Json -AsHashtable).taskArns)
            }
            if ($found.Count -gt 1) { throw 'lifecycle.delivery.executionAmbiguous' }
            if ($found.Count -eq 1) { $Record.executionId = [string] $found[0]; & $Persist $Record | Out-Null }
        }
        if ($Record.executionId) {
            if ($Record.executionId -cnotmatch '^arn:aws:ecs:[a-z0-9-]+:[0-9]{12}:task/[A-Za-z0-9_-]+/[0-9a-f]{32}$') { throw 'lifecycle.delivery.executionIdInvalid' }
            $described = Invoke-AwsLifecycleCli $Context @('ecs', 'describe-tasks', '--cluster', $Expected.cluster, '--tasks', $Record.executionId)
            if ($described.exitCode -ne 0) { throw 'lifecycle.delivery.executionUnavailable' }
            $tasks = @(($described.text | ConvertFrom-Json -AsHashtable -Depth 16).tasks)
            if ($tasks.Count -eq 1) {
                $next = Get-AwsDeliveryTaskStatus $tasks[0] $Expected $Record.attemptId
                if ($Record.status -cne $next) { $Record.status = $next; & $Persist $Record | Out-Null }
                if ($next -ceq 'Succeeded') { return $Record }
                if ($next -ceq 'Failed') { throw 'lifecycle.delivery.jobFailed' }
            }
        }
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'lifecycle.delivery.executionPending' }
        Start-Sleep -Seconds $PollSeconds
    } while ($true)
}

Export-ModuleMember -Function Invoke-AwsDeliveryMaintenance, Get-AwsDeliveryTaskStatus, Get-AwsDeliveryTaskHash
