Set-StrictMode -Version Latest

function Assert-OperationsPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Operations, [Parameter(Mandatory)] $Topology)

    $schema = Join-Path $PSScriptRoot '../contracts/schemas/messaging-operations-policy-v1.schema.json'
    if (-not (($Operations | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile $schema -ErrorAction SilentlyContinue)) {
        throw 'Invalid MessagingOperationsPolicy v1.'
    }
    $expectedKind = switch ($Operations.provider) {
        'azure-service-bus' { 'AzureServiceBusPolicy' }
        'aws-sns-sqs' { 'AwsSnsSqsPolicy' }
        'rabbitmq' { 'RabbitMqPolicy' }
    }
    if ($Topology.kind -cne $expectedKind -or $Operations.product -cne $Topology.product -or
        $Operations.environment -cne $Topology.environment) {
        throw 'Operations and topology must agree on product, environment and provider.'
    }
    $actual = @($Operations.consumers.id | Sort-Object)
    $expected = @($Topology.consumers.id | Sort-Object)
    if (@($actual | Select-Object -Unique).Count -ne $actual.Count -or
        ($actual -join ',') -cne ($expected -join ',')) {
        throw 'Operations consumers must match topology exactly without duplicates.'
    }
    $operatorKeys = @($Operations.operatorIdentities.PSObject.Properties.Name | Sort-Object)
    if (($actual -join ',') -cne ($operatorKeys -join ',')) { throw 'Every consumer requires an operator identity.' }
    $identities = @($Operations.operatorIdentities.PSObject.Properties.Value)
    if (@($identities | Select-Object -Unique).Count -ne $identities.Count) { throw 'Operator identities must be distinct per consumer.' }
    $workloads = switch ($Operations.provider) {
        'azure-service-bus' { @($Topology.workloadPrincipalIds.PSObject.Properties.Value) }
        'aws-sns-sqs' { @($Topology.workloadRoleNames.PSObject.Properties.Value) }
        'rabbitmq' { @($Topology.workloadUserNames.PSObject.Properties.Value) }
    }
    if (@($identities | Where-Object { $_ -in $workloads }).Count -gt 0) { throw 'Operator identities must not be application workload identities.' }
    if ($Operations.provider -ceq 'azure-service-bus') {
        foreach ($identity in $identities) {
            $principal = [guid]::Empty
            if (-not [guid]::TryParseExact($identity, 'D', [ref] $principal) -or $principal -eq [guid]::Empty) {
                throw 'Azure operator identities must be principal UUIDs.'
            }
        }
    }
    if ($Operations.provider -ceq 'rabbitmq') {
        if ($Operations.notificationTargets.Count -ne 0) {
            throw 'RabbitMQ routes notifications through Alertmanager, not cloud notification targets.'
        }
    }
    else {
        if ($Operations.notificationTargets.Count -eq 0) { throw 'Cloud alerts require notification targets.' }
        foreach ($target in $Operations.notificationTargets) {
            $pattern = if ($Operations.provider -ceq 'azure-service-bus') {
                '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9._()-]+/providers/Microsoft.Insights/actionGroups/[A-Za-z0-9._()-]+$'
            }
            else { '^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+$' }
            if ($target -cnotmatch $pattern) { throw 'Invalid notification target for this provider.' }
        }
    }
    foreach ($consumer in $Operations.consumers) {
        $physical = @($Topology.consumers | Where-Object id -CEQ $consumer.id)[0]
        $hasDlq = switch ($Operations.provider) {
            'azure-service-bus' { $true }
            'aws-sns-sqs' { [bool] $physical.redrive.enabled }
            'rabbitmq' { [bool] $physical.deadLetter.enabled }
        }
        if (-not $hasDlq -and ($null -ne $consumer.deadLetterThreshold -or
            $consumer.quarantineReviewHours -ne 0 -or $consumer.replay.enabled)) {
            throw "Consumer '$($consumer.id)' has no DLQ; quarantine, DLQ alerts and replay must be disabled."
        }
        if ($hasDlq -and ($null -eq $consumer.deadLetterThreshold -or $consumer.quarantineReviewHours -lt 1)) {
            throw "Consumer '$($consumer.id)' requires a DLQ threshold and a quarantine review deadline."
        }
        if ($Operations.provider -cne 'aws-sns-sqs' -and $null -ne $consumer.oldestMessageAgeSeconds) {
            throw 'Only AWS exposes the supported per-queue oldest-message-age metric.'
        }
        if ($Operations.provider -ceq 'aws-sns-sqs') {
            if ($null -eq $consumer.oldestMessageAgeSeconds -or
                $consumer.oldestMessageAgeSeconds -ge $physical.messageRetentionSeconds) {
                throw 'AWS oldest-message-age threshold must precede source retention.'
            }
            if ($hasDlq -and ($consumer.quarantineReviewHours * 3600) -ge
                ($physical.redrive.deadLetterMessageRetentionSeconds - $physical.messageRetentionSeconds)) {
                throw 'Quarantine review must precede the worst-case remaining SQS DLQ retention.'
            }
        }
    }
}

function ConvertTo-OperationsTerraformInput {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Operations, [Parameter(Mandatory)] $Topology)
    Assert-OperationsPolicy -Operations $Operations -Topology $Topology
    $consumers = [ordered] @{}
    foreach ($consumer in @($Operations.consumers | Sort-Object id)) {
        $consumers[$consumer.id] = [ordered] @{
            backlog_threshold = $consumer.backlogThreshold
            replay_enabled = $consumer.replay.enabled
            dead_letter_threshold = $consumer.deadLetterThreshold
            oldest_message_age_seconds = $consumer.oldestMessageAgeSeconds
        }
    }
    $operators = [ordered] @{}
    foreach ($property in @($Operations.operatorIdentities.PSObject.Properties | Sort-Object Name)) { $operators[$property.Name] = [string] $property.Value }
    return [ordered] @{ operations = [ordered] @{ notification_targets = @($Operations.notificationTargets); operator_identities = $operators; consumers = $consumers } }
}

function ConvertTo-RabbitMqAlertRules {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Operations, [Parameter(Mandatory)] $Topology)
    Assert-OperationsPolicy -Operations $Operations -Topology $Topology
    $rules = @()
    foreach ($consumer in @($Operations.consumers | Sort-Object id)) {
        $physical = @($Topology.consumers | Where-Object id -CEQ $consumer.id)[0]
        $selector = 'vhost=' + (ConvertTo-Json -Compress ([string] $Topology.virtualHost)) + ',queue=' +
            (ConvertTo-Json -Compress ([string] $physical.queueName))
        $labels = [ordered] @{ product = $Operations.product; environment = $Operations.environment; consumer = $consumer.id; severity = 'warning' }
        $rules += [ordered] @{ alert = 'HexagonMessagingBacklog'; expr = "sum(rabbitmq_queue_messages_ready{$selector}) >= $($consumer.backlogThreshold)"; 'for' = '5m'; labels = $labels }
        $rules += [ordered] @{ alert = 'HexagonMessagingNoConsumers'; expr = "sum(rabbitmq_queue_consumers{$selector}) == 0 and sum(rabbitmq_queue_messages_ready{$selector}) > 0"; 'for' = '5m'; labels = $labels }
        $rules += [ordered] @{ alert = 'HexagonMessagingMetricsMissing'; expr = "absent(rabbitmq_queue_messages_ready{$selector})"; 'for' = '5m'; labels = $labels }
        if ($physical.deadLetter.enabled) {
            $dlq = 'vhost=' + (ConvertTo-Json -Compress ([string] $Topology.virtualHost)) + ',queue=' +
                (ConvertTo-Json -Compress ([string] $physical.deadLetter.queueName))
            $rules += [ordered] @{ alert = 'HexagonMessagingDeadLetters'; expr = "sum(rabbitmq_queue_messages_ready{$dlq}) >= $($consumer.deadLetterThreshold)"; 'for' = '1m'; labels = $labels }
        }
    }
    # JSON is a YAML subset accepted by Prometheus rule_files; no Kubernetes dependency.
    return [ordered] @{ groups = @([ordered] @{ name = "$($Operations.product)-$($Operations.environment)-messaging"; rules = $rules }) }
}

Export-ModuleMember -Function Assert-OperationsPolicy, ConvertTo-OperationsTerraformInput, ConvertTo-RabbitMqAlertRules
