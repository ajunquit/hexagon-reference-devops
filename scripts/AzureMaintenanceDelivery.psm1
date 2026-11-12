Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AzureEnvironmentStore.psm1')
Import-Module (Join-Path $PSScriptRoot 'LifecycleNative.psm1')
Import-Module (Join-Path $PSScriptRoot 'PlatformBootstrap.psm1')

function Get-DeliveryAzureObject([hashtable] $Context, [string] $Id) {
    if ($Id -match '[?#%\\\s]|/[.][.]?(?:/|$)') { throw 'lifecycle.delivery.resourceIdInvalid' }
    $response = Invoke-AzureLifecycleHttp $Context GET "https://management.azure.com${Id}?api-version=2024-03-01"
    if ($response.status -ne 200) { throw 'lifecycle.delivery.resourceUnavailable' }
    return [Text.Encoding]::UTF8.GetString($response.bytes) | ConvertFrom-Json -AsHashtable -Depth 40
}

function Get-DeliveryJobExecutions([hashtable] $Context, [string] $JobId) {
    $prefix = "https://management.azure.com$JobId/executions"
    $uri = "$prefix`?api-version=2024-03-01"
    $items = [Collections.Generic.List[object]]::new(); $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    while ($uri) {
        $address = [uri] $uri
        if ($address.Scheme -cne 'https' -or $address.Host -cne 'management.azure.com' -or $address.Port -ne 443 -or $address.UserInfo -or $address.Fragment -or
            $address.AbsolutePath -cne "$JobId/executions" -or -not $seen.Add($uri) -or $seen.Count -gt 20) { throw 'lifecycle.delivery.executionsPageInvalid' }
        $response = Invoke-AzureLifecycleHttp $Context GET $uri
        if ($response.status -ne 200) { throw 'lifecycle.delivery.executionsUnavailable' }
        $page = [Text.Encoding]::UTF8.GetString($response.bytes) | ConvertFrom-Json -AsHashtable -Depth 40
        if (-not $page.ContainsKey('value') -or $page.value -isnot [Collections.IList]) { throw 'lifecycle.delivery.executionsIncomplete' }
        foreach ($item in $page.value) {
            if ($item.name -cnotmatch '^[a-zA-Z0-9_.()-]+$' -or ($item.ContainsKey('id') -and $item.id -ine "$JobId/executions/$($item.name)")) { throw 'lifecycle.delivery.executionIdInvalid' }
            $execution = Get-DeliveryAzureObject $Context "$JobId/executions/$($item.name)"
            $execution['id'] = "$JobId/executions/$($item.name)"
            $items.Add($execution)
            if ($items.Count -gt 500) { throw 'lifecycle.delivery.executionsTooMany' }
        }
        $uri = $(if ($page.ContainsKey('nextLink')) { [string] $page.nextLink } else { '' })
    }
    return $items.ToArray()
}

function ConvertTo-DeliveryJobTemplate([hashtable] $Template) {
    if ($Template.containers.Count -ne 1 -or ($Template.ContainsKey('initContainers') -and @($Template.initContainers).Count -gt 0)) { throw 'lifecycle.delivery.jobTemplateInvalid' }
    $container = $Template.containers[0]
    if ($container.name -cne 'maintenance' -or ($container.ContainsKey('command') -and @($container.command).Count -gt 0) -or
        ($container.ContainsKey('volumeMounts') -and @($container.volumeMounts).Count -gt 0) -or
        $container.resources.cpu -ne 0.5 -or $container.resources.memory -cne '1Gi') { throw 'lifecycle.delivery.jobTemplateInvalid' }
    $environment = @{}
    foreach ($item in $container.env) {
        if ($environment.ContainsKey($item.name)) { throw 'lifecycle.delivery.jobEnvironmentInvalid' }
        if ($item.ContainsKey('secretRef') -and $item.secretRef) {
            if ($item.ContainsKey('value') -and $item.value) { throw 'lifecycle.delivery.jobEnvironmentInvalid' }
            $environment[$item.name] = @{ secretRef = [string] $item.secretRef }
        }
        elseif ($item.ContainsKey('value')) { $environment[$item.name] = [string] $item.value }
        else { throw 'lifecycle.delivery.jobEnvironmentInvalid' }
    }
    return @{ name = 'maintenance'; image = [string] $container.image; args = @($(if ($container.ContainsKey('args') -and $null -ne $container.args) { @($container.args) } else { @() })); environment = $environment; cpu = 0.5; memory = '1Gi' }
}

function Assert-DeliveryJobTemplate([hashtable] $Template, [hashtable] $Expected, [string] $AttemptId) {
    $actual = ConvertTo-DeliveryJobTemplate $Template
    $environment = @{} + $Expected.environment
    if ($AttemptId) { $environment['HEXAGON_DELIVERY_ATTEMPT'] = $AttemptId }
    $desired = @{} + $Expected; $desired.environment = $environment
    if ((ConvertTo-PlatformBootstrapJson $actual) -cne (ConvertTo-PlatformBootstrapJson $desired)) { throw 'lifecycle.delivery.jobTemplateChanged' }
}

function Invoke-AzureDeliveryMaintenance {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context, [string] $JobId, [hashtable] $Expected, [hashtable] $Record,
        [Parameter(Mandatory)][scriptblock] $Persist, [int] $TimeoutSeconds = 1900, [int] $PollSeconds = 10)
    if (-not $PSCmdlet.ShouldProcess($JobId, 'Run or reconcile the recorded maintenance execution')) { return }
    Assert-AzureLifecycleLease $Context
    $job = Get-DeliveryAzureObject $Context $JobId
    if ($job.id -ine $JobId -or $job.properties.configuration.triggerType -cne 'Manual' -or $job.properties.configuration.replicaRetryLimit -ne 0 -or
        $job.properties.configuration.replicaTimeout -ne 1800) { throw 'lifecycle.delivery.jobConfigurationChanged' }
    Assert-DeliveryJobTemplate $job.properties.template $Expected ''
    $hash = Get-LifecycleBytesHash ([Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson $Expected)))
    if ($null -ne $Record -and ($Record.jobId -ine $JobId -or $Record.templateSha256 -cne $hash)) { throw 'lifecycle.delivery.jobEvidenceStale' }
    if ($null -ne $Record -and $Record.status -ceq 'Failed') { throw 'lifecycle.delivery.failedExecutionRequiresInvestigation' }
    if ($null -eq $Record) {
        $Record = @{ jobId = $JobId; attemptId = [guid]::NewGuid().ToString(); templateSha256 = $hash; executionId = $null; status = 'Starting' }
        # Durable intent precedes the non-idempotent POST. Recovery only adopts this exact marker.
        & $Persist $Record | Out-Null
        $template = (ConvertTo-PlatformBootstrapJson $job.properties.template) | ConvertFrom-Json -AsHashtable -Depth 32
        $template.containers[0].env = @($template.containers[0].env) + @(@{ name = 'HEXAGON_DELIVERY_ATTEMPT'; value = $Record.attemptId })
        $body = Join-Path $Context.runtime "job-$($Record.attemptId).json"
        [IO.File]::WriteAllText($body, (ConvertTo-PlatformBootstrapJson $template))
        Assert-AzureLifecycleLease $Context
        $renew = (Get-Command Assert-AzureLifecycleLease).ScriptBlock
        $heartbeat = { & $renew $Context }.GetNewClosure()
        $native = Invoke-LifecycleCommand az @('rest', '--method', 'post', '--url', "https://management.azure.com$JobId/start?api-version=2024-03-01", '--body', "@$body", '--subscription', $Context.inventory.target.subscriptionId, '--output', 'json', '--only-show-errors') -TimeoutSeconds 120 -Heartbeat $heartbeat
        if ($native.exitCode -ne 0) { throw 'lifecycle.delivery.jobStartUncertain' }
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        Assert-AzureLifecycleLease $Context
        if ($Record.executionId) {
            if (-not $Record.executionId.StartsWith("$JobId/executions/", [StringComparison]::OrdinalIgnoreCase) -or $Record.executionId.Substring($JobId.Length + 12) -cnotmatch '^[a-zA-Z0-9_.()-]+$') { throw 'lifecycle.delivery.executionIdInvalid' }
            $executions = @(Get-DeliveryAzureObject $Context $Record.executionId)
        }
        else {
            $executions = @(Get-DeliveryJobExecutions $Context $JobId | Where-Object {
                @($_.properties.template.containers[0].env | Where-Object { $_.name -ceq 'HEXAGON_DELIVERY_ATTEMPT' -and $_.value -ceq $Record.attemptId }).Count -eq 1
            })
        }
        if ($executions.Count -gt 1) { throw 'lifecycle.delivery.executionAmbiguous' }
        if ($executions.Count -eq 1) {
            $execution = $executions[0]
            Assert-DeliveryJobTemplate $execution.properties.template $Expected $Record.attemptId
            $Record.executionId = $(if ($Record.executionId) { $Record.executionId } else { $execution.id })
            $observed = [string] $execution.properties.status
            if ($observed -cnotin @('Processing', 'Running', 'Succeeded', 'Failed', 'Stopped', 'Canceled', 'Unknown')) { throw 'lifecycle.delivery.executionStatusInvalid' }
            $next = $(if ($observed -ceq 'Succeeded') { 'Succeeded' } elseif ($observed -cin @('Failed', 'Stopped', 'Canceled')) { 'Failed' } else { 'Running' })
            if ($Record.status -cne $next) { $Record.status = $next; & $Persist $Record | Out-Null }
            if ($next -ceq 'Succeeded') { return $Record }
            if ($next -ceq 'Failed') { throw 'lifecycle.delivery.jobFailed' }
        }
        # Never repeat start after an ambiguous request, even if the execution is not visible yet.
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'lifecycle.delivery.executionPending' }
        Start-Sleep -Seconds $PollSeconds
    } while ($true)
}

Export-ModuleMember -Function Invoke-AzureDeliveryMaintenance, Assert-DeliveryJobTemplate, ConvertTo-DeliveryJobTemplate
