Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'LocalMessagingSupport.psm1')

# Local topology of RabbitMQ. LocalMessaging.psm1 discovers this module and calls these functions inside it;
# it exports nothing.

function Get-LocalMessagingProvider { return 'rabbitmq' }

function Get-LocalMessagingTopologyKind { return 'RabbitMqPolicy' }

# <Name>Contracts.psm1 and Test-<Name>Policy.ps1 validate its delivery policy.
function Get-LocalMessagingContracts { return 'RabbitMq' }

function ConvertTo-ProviderLocalMessaging($Manifest, $Policy) { return ConvertTo-RabbitMqLocalMessaging -Manifest $Manifest -Policy $Policy }

# Rejects a start that the emulator does not allow, such as unaccepted license terms.
function Assert-LocalMessagingStart([bool] $AcceptLicense) { }

# Process variables that Docker Compose needs while it starts or stops the emulator.
function Get-LocalMessagingStartEnvironment { return @{} }

function Get-LocalMessagingStopEnvironment { return @{} }

function Test-LocalMessagingReady($Generated, [string] $ProjectName) {
    $generated = $Generated; $projectName = $ProjectName; $ready = $false
    $definitions = Get-Content -Raw -LiteralPath `
        (Join-Path $generated.OutputDirectory 'rabbitmq-definitions.json') | ConvertFrom-Json
    $virtualHost = [string] $definitions.vhosts[0].name
    $expectedQueues = @($definitions.queues | ForEach-Object { [string] $_.name })
    $actual = & docker compose --project-name $projectName --file $generated.ComposeFile `
        exec -T rabbitmq rabbitmqctl list_queues -p $virtualHost name --formatter json 2>$null
    if ($LASTEXITCODE -eq 0) {
        $actualText = ($actual | ForEach-Object ToString) -join "`n"
        $ready = @($expectedQueues | Where-Object { -not $actualText.Contains($_) }).Count -eq 0
    }
    return $ready
}

function ConvertTo-RabbitMqLocalMessaging {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Manifest,
        [AllowNull()]
        [pscustomobject] $Policy
    )

    $virtualHost = if ($null -eq $Policy) { "$($Manifest.product)-local" } else { [string] $Policy.virtualHost }
    $encodedVirtualHost = [Uri]::EscapeDataString($virtualHost)
    $connectionString = "amqp://guest:guest@localhost:5672/$encodedVirtualHost"
    $workloads = [ordered] @{}
    $exchanges = [Collections.Generic.List[object]]::new()
    $quarantinePolicies = [Collections.Generic.List[object]]::new()
    $queues = [Collections.Generic.List[object]]::new()
    $bindings = [Collections.Generic.List[object]]::new()

    foreach ($destination in $Manifest.destinations) {
        $policyDestination = Get-PolicyItem -Policy $Policy -Collection destinations -Id ([string] $destination.id)
        $exchangeName = if ($null -eq $policyDestination) { [string] $destination.id } else { [string] $policyDestination.exchangeName }
        $exchanges.Add([ordered] @{ name = $exchangeName; vhost = $virtualHost; type = 'topic'; durable = $true; auto_delete = $false; internal = $false; arguments = @{} })
        foreach ($workload in $destination.publisherWorkloads) {
            Add-LocalEnvironmentValue $workloads ([string] $workload) "Messaging__RabbitMq__Destinations__$($destination.id)__ConnectionString" $connectionString
            Add-LocalEnvironmentValue $workloads ([string] $workload) "Messaging__RabbitMq__Destinations__$($destination.id)__Exchange" $exchangeName
        }

        foreach ($consumer in @($Manifest.consumers | Where-Object { [string] $_.destination -ceq [string] $destination.id })) {
            $policyConsumer = Get-PolicyItem -Policy $Policy -Collection consumers -Id ([string] $consumer.id)
            $queueName = if ($null -eq $policyConsumer) { [string] $consumer.id } else { [string] $policyConsumer.queueName }
            $deliveryLimit = if ($null -eq $policyConsumer) { 3 } else { [int] $policyConsumer.deliveryLimit }
            $arguments = [ordered] @{ 'x-queue-type' = 'quorum'; 'x-delivery-limit' = $deliveryLimit }
            $deadLetterEnabled = $null -ne $policyConsumer -and [bool] $policyConsumer.deadLetter.enabled
            if ($deadLetterEnabled) {
                $deadLetterExchange = [string] $policyConsumer.deadLetter.exchangeName
                $deadLetterQueue = [string] $policyConsumer.deadLetter.queueName
                $deadLetterRoutingKey = [string] $policyConsumer.deadLetter.routingKey
                $quarantinePolicies.Add([ordered] @{
                    name = "quarantine-$queueName"; vhost = $virtualHost
                    pattern = '^' + [regex]::Escape($deadLetterQueue) + '$'
                    'apply-to' = 'queues'; priority = 20; definition = @{ 'delivery-limit' = -1 }
                })
                $arguments['x-dead-letter-exchange'] = $deadLetterExchange
                $arguments['x-dead-letter-routing-key'] = $deadLetterRoutingKey
                $exchanges.Add([ordered] @{ name = $deadLetterExchange; vhost = $virtualHost; type = 'direct'; durable = $true; auto_delete = $false; internal = $false; arguments = @{} })
                $queues.Add([ordered] @{ name = $deadLetterQueue; vhost = $virtualHost; durable = $true; auto_delete = $false; arguments = [ordered] @{ 'x-queue-type' = 'quorum' } })
                $bindings.Add([ordered] @{ source = $deadLetterExchange; vhost = $virtualHost; destination = $deadLetterQueue; destination_type = 'queue'; routing_key = $deadLetterRoutingKey; arguments = @{} })
            }
            $queues.Add([ordered] @{ name = $queueName; vhost = $virtualHost; durable = $true; auto_delete = $false; arguments = $arguments })
            $routingKeys = if ([string] $consumer.routing.mode -ceq 'all') { @('#') } else { @($consumer.routing.eventTypes) }
            foreach ($routingKey in $routingKeys) {
                $bindings.Add([ordered] @{ source = $exchangeName; vhost = $virtualHost; destination = $queueName; destination_type = 'queue'; routing_key = [string] $routingKey; arguments = @{} })
            }

            Add-LocalEnvironmentValue $workloads ([string] $consumer.workload) "Messaging__RabbitMq__Destinations__$($destination.id)__ConnectionString" $connectionString
            Add-LocalEnvironmentValue $workloads ([string] $consumer.workload) "Messaging__RabbitMq__Destinations__$($destination.id)__Exchange" $exchangeName
            Add-LocalEnvironmentValue $workloads ([string] $consumer.workload) "Messaging__RabbitMq__Consumers__$($consumer.id)__ConnectionString" $connectionString
            Add-LocalEnvironmentValue $workloads ([string] $consumer.workload) "Messaging__RabbitMq__Consumers__$($consumer.id)__Exchange" $exchangeName
            Add-LocalEnvironmentValue $workloads ([string] $consumer.workload) "Messaging__RabbitMq__Consumers__$($consumer.id)__Queue" $queueName
        }
    }

    $definitions = [ordered] @{
        users       = @([ordered] @{ name = 'guest'; password_hash = '9/1i+jKFRpbTRV1PtRnzFFYibT3cEpP92JeZ8YKGtflf4e/u'; tags = @('administrator') })
        vhosts      = @([ordered] @{ name = $virtualHost })
        permissions = @([ordered] @{ user = 'guest'; vhost = $virtualHost; configure = '.*'; write = '.*'; read = '.*' })
        policies    = @($quarantinePolicies)
        exchanges   = @($exchanges)
        queues      = @($queues)
        bindings    = @($bindings)
    }
    $compose = @'
services:
  rabbitmq:
    image: rabbitmq:4.1-alpine
    ports:
      - "5672:5672"
    volumes:
      - ./rabbitmq.conf:/etc/rabbitmq/rabbitmq.conf:ro
      - ./rabbitmq-definitions.json:/etc/rabbitmq/definitions.json:ro
'@
    $configuration = @'
definitions.import_backend = local_filesystem
definitions.local.path = /etc/rabbitmq/definitions.json
definitions.skip_if_unchanged = true
loopback_users.guest = false
'@
    return [pscustomobject] @{
        Workloads = $workloads
        Files     = [ordered] @{
            'compose.yaml'              = $compose
            'rabbitmq.conf'             = $configuration
            'rabbitmq-definitions.json' = ($definitions | ConvertTo-Json -Depth 20)
        }
    }
}

Export-ModuleMember -Function @()
