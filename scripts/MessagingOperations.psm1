Set-StrictMode -Version Latest

# The operations of each messaging provider (docs/separacion-por-nube.md): a module named
# <Provider>OperationsPolicy.psm1 next to this one declares its logical provider and implements the
# Operations* functions inside it. The modules export nothing, so the clouds of a template never collide.
$script:providers = $null

function Get-OperationsProviderModules {
    if ($null -eq $script:providers) {
        $script:providers = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*OperationsPolicy.psm1' -File | Sort-Object Name |
            ForEach-Object { Import-Module $_.FullName -PassThru -DisableNameChecking })
    }
    return $script:providers
}

# The logical names of the messaging providers of this repository.
function Get-OperationsProviders { return [string[]] @(Get-OperationsProviderModules | ForEach-Object { & $_ { Get-OperationsProvider } }) }

function Get-OperationsProviderModule([string] $Provider) {
    $matching = @(Get-OperationsProviderModules | Where-Object { (& $_ { Get-OperationsProvider }) -ceq $Provider })
    if ($matching.Count -ne 1) { throw 'Unsupported operations provider.' }
    return $matching[0]
}

function Invoke-OperationsProvider([Management.Automation.PSModuleInfo] $Module, [string] $Name, [object[]] $Arguments = @()) {
    return & $Module { param($command, $values) & $command @values } $Name $Arguments
}

function Assert-OperationsPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Operations, [Parameter(Mandatory)] $Topology)

    $schema = Join-Path $PSScriptRoot '../contracts/schemas/messaging-operations-policy-v1.schema.json'
    if (-not (($Operations | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile $schema -ErrorAction SilentlyContinue)) {
        throw 'Invalid MessagingOperationsPolicy v1.'
    }
    $provider = Get-OperationsProviderModule $Operations.provider
    if ($Topology.kind -cne (Invoke-OperationsProvider $provider Get-OperationsTopologyKind) -or $Operations.product -cne $Topology.product -or
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
    $workloads = @(Invoke-OperationsProvider $provider Get-OperationsWorkloadIdentities @(, $Topology))
    if (@($identities | Where-Object { $_ -in $workloads }).Count -gt 0) { throw 'Operator identities must not be application workload identities.' }
    Invoke-OperationsProvider $provider Assert-OperationsIdentities @(, $identities)
    Invoke-OperationsProvider $provider Assert-OperationsNotifications @(, $Operations)
    foreach ($consumer in $Operations.consumers) {
        $physical = @($Topology.consumers | Where-Object id -CEQ $consumer.id)[0]
        $hasDlq = [bool] (Invoke-OperationsProvider $provider Test-OperationsDeadLetter @(, $physical))
        if (-not $hasDlq -and ($null -ne $consumer.deadLetterThreshold -or
            $consumer.quarantineReviewHours -ne 0 -or $consumer.replay.enabled)) {
            throw "Consumer '$($consumer.id)' has no DLQ; quarantine, DLQ alerts and replay must be disabled."
        }
        if ($hasDlq -and ($null -eq $consumer.deadLetterThreshold -or $consumer.quarantineReviewHours -lt 1)) {
            throw "Consumer '$($consumer.id)' requires a DLQ threshold and a quarantine review deadline."
        }
        Invoke-OperationsProvider $provider Assert-OperationsConsumer @($consumer, $physical, $hasDlq)
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

Export-ModuleMember -Function Assert-OperationsPolicy, ConvertTo-OperationsTerraformInput, ConvertTo-RabbitMqAlertRules, Get-OperationsProviderModule, Get-OperationsProviders, Invoke-OperationsProvider
