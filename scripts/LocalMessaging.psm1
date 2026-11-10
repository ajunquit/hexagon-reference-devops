Set-StrictMode -Version Latest

function Get-LocalMessagingManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $BackendPath
    )

    $backendRoot = (Resolve-Path -LiteralPath $BackendPath).Path
    $manifestPath = Join-Path $backendRoot '.hexagon/messaging-requirements.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Backend messaging manifest is missing: $manifestPath"
    }

    $json = Get-Content -Raw -LiteralPath $manifestPath
    $manifest = $json | ConvertFrom-Json
    $schemaReference = [string] $manifest.'$schema'
    if ($schemaReference -notmatch '^(?!/)(?!.*(?:^|[\\/])\.\.(?:[\\/]|$))[A-Za-z0-9._/\\-]+$') {
        throw "Backend manifest schema reference '$schemaReference' is not a safe relative path."
    }

    $schemaPath = [IO.Path]::GetFullPath(
        (Join-Path (Split-Path -Parent $manifestPath) $schemaReference)
    )
    if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
        throw "Backend messaging schema is missing: $schemaPath"
    }
    if (-not ($json | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
        throw "Backend manifest '$manifestPath' does not satisfy its schema."
    }

    $destinationIds = @($manifest.destinations | ForEach-Object { [string] $_.id })
    if (@($destinationIds | Select-Object -Unique).Count -ne $destinationIds.Count) {
        throw 'Backend messaging destination ids must be unique.'
    }
    $consumerIds = @($manifest.consumers | ForEach-Object { [string] $_.id })
    if (@($consumerIds | Select-Object -Unique).Count -ne $consumerIds.Count) {
        throw 'Backend messaging consumer ids must be unique.'
    }
    foreach ($consumer in $manifest.consumers) {
        if ([string] $consumer.destination -notin $destinationIds) {
            throw "Consumer '$($consumer.id)' references unknown destination '$($consumer.destination)'."
        }
    }

    return [pscustomobject] @{
        BackendRoot = $backendRoot
        Manifest    = $manifest
    }
}

function Assert-LocalMessagingPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Manifest,

        [Parameter(Mandatory = $true)]
        [pscustomobject] $Policy
    )

    $expectedKind = switch ([string] $Manifest.provider) {
        'azure-service-bus' { 'AzureServiceBusPolicy' }
        'aws-sns-sqs' { 'AwsSnsSqsPolicy' }
        'rabbitmq' { 'RabbitMqPolicy' }
        default { throw "Unsupported messaging provider '$($Manifest.provider)'." }
    }
    if ([string] $Policy.kind -cne $expectedKind) {
        throw "Policy kind '$($Policy.kind)' does not match provider '$($Manifest.provider)'."
    }
    if ([string] $Policy.product -cne [string] $Manifest.product) {
        throw "Policy product '$($Policy.product)' does not match backend product '$($Manifest.product)'."
    }

    foreach ($collectionName in @('destinations', 'consumers')) {
        $manifestIds = @($Manifest.$collectionName | ForEach-Object { [string] $_.id } | Sort-Object)
        $policyIds = @($Policy.$collectionName | ForEach-Object { [string] $_.id } | Sort-Object)
        if (($manifestIds -join "`n") -cne ($policyIds -join "`n")) {
            throw "Policy $collectionName must match the backend manifest exactly."
        }
    }
}

function Get-PolicyItem {
    param(
        [AllowNull()]
        [pscustomobject] $Policy,
        [Parameter(Mandatory = $true)]
        [string] $Collection,
        [Parameter(Mandatory = $true)]
        [string] $Id
    )

    if ($null -eq $Policy) { return $null }
    return @($Policy.$Collection | Where-Object { [string] $_.id -ceq $Id })[0]
}

function Add-LocalEnvironmentValue {
    param(
        [Parameter(Mandatory = $true)]
        [Collections.Specialized.OrderedDictionary] $Workloads,
        [Parameter(Mandatory = $true)]
        [string] $Workload,
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    if (-not $Workloads.Contains($Workload)) {
        $Workloads.Add($Workload, [ordered] @{})
    }
    $Workloads[$Workload][$Name] = $Value
}

function ConvertTo-AzureLocalMessaging {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Manifest,
        [AllowNull()]
        [pscustomobject] $Policy
    )

    $workloads = [ordered] @{}
    if ($null -ne $Policy) {
        foreach ($entity in @($Policy.destinations) + @($Policy.consumers)) {
            if ([Xml.XmlConvert]::ToTimeSpan([string] $entity.defaultMessageTtl) -gt [TimeSpan]::FromHours(1)) {
                throw 'Azure emulator TTL cannot exceed PT1H. Supply an explicit local policy; cloud TTL values are not silently reduced.'
            }
        }
        foreach ($destination in $Policy.destinations) {
            if ([Xml.XmlConvert]::ToTimeSpan([string] $destination.duplicateDetectionHistory) -gt [TimeSpan]::FromMinutes(5)) {
                throw 'Azure emulator duplicate detection window cannot exceed PT5M. Supply an explicit local policy; cloud windows are not silently reduced.'
            }
        }
    }
    $topics = @()
    foreach ($destination in $Manifest.destinations) {
        $policyDestination = Get-PolicyItem -Policy $Policy -Collection destinations -Id ([string] $destination.id)
        $topicName = if ($null -eq $policyDestination) { [string] $destination.id } else { [string] $policyDestination.topicName }
        $topic = [ordered] @{
            Name          = $topicName
            Properties    = [ordered] @{
                DefaultMessageTimeToLive               = if ($null -eq $policyDestination) { 'PT1H' } else { [string] $policyDestination.defaultMessageTtl }
                DuplicateDetectionHistoryTimeWindow    = if ($null -eq $policyDestination) { 'PT20S' } else { [string] $policyDestination.duplicateDetectionHistory }
                RequiresDuplicateDetection             = if ($null -eq $policyDestination) { $false } else { [bool] $policyDestination.duplicateDetectionEnabled }
            }
            Subscriptions = @()
        }

        foreach ($workload in $destination.publisherWorkloads) {
            Add-LocalEnvironmentValue $workloads ([string] $workload) 'ConnectionStrings__servicebus' 'Endpoint=sb://localhost;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=SAS_KEY_VALUE;UseDevelopmentEmulator=true;'
            Add-LocalEnvironmentValue $workloads ([string] $workload) "Messaging__AzureServiceBus__Destinations__$($destination.id)__Topic" $topicName
        }

        foreach ($consumer in @($Manifest.consumers | Where-Object { [string] $_.destination -ceq [string] $destination.id })) {
            $policyConsumer = Get-PolicyItem -Policy $Policy -Collection consumers -Id ([string] $consumer.id)
            $subscriptionName = if ($null -eq $policyConsumer) { [string] $consumer.id } else { [string] $policyConsumer.subscriptionName }
            $subscription = [ordered] @{
                Name       = $subscriptionName
                Properties = [ordered] @{
                    DeadLetteringOnMessageExpiration = if ($null -eq $policyConsumer) { $false } else { [bool] $policyConsumer.deadLetterOnMessageExpiration }
                    DefaultMessageTimeToLive         = if ($null -eq $policyConsumer) { 'PT1H' } else { [string] $policyConsumer.defaultMessageTtl }
                    LockDuration                     = if ($null -eq $policyConsumer) { 'PT1M' } else { [string] $policyConsumer.lockDuration }
                    MaxDeliveryCount                 = if ($null -eq $policyConsumer) { 3 } else { [int] $policyConsumer.maxDeliveryCount }
                    ForwardDeadLetteredMessagesTo    = ''
                    ForwardTo                        = ''
                    RequiresSession                  = $false
                }
            }
            if ([string] $consumer.routing.mode -ceq 'include') {
                $subscription.Rules = @(
                    $consumer.routing.eventTypes | ForEach-Object {
                        [ordered] @{
                            Name       = [string] $_
                            Properties = [ordered] @{
                                FilterType        = 'Correlation'
                                CorrelationFilter = [ordered] @{ Label = [string] $_ }
                            }
                        }
                    }
                )
            }
            $topic.Subscriptions += $subscription

            Add-LocalEnvironmentValue $workloads ([string] $consumer.workload) 'ConnectionStrings__servicebus' 'Endpoint=sb://localhost;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=SAS_KEY_VALUE;UseDevelopmentEmulator=true;'
            Add-LocalEnvironmentValue $workloads ([string] $consumer.workload) "Messaging__AzureServiceBus__Destinations__$($destination.id)__Topic" $topicName
            Add-LocalEnvironmentValue $workloads ([string] $consumer.workload) "Messaging__AzureServiceBus__Consumers__$($consumer.id)__Topic" $topicName
            Add-LocalEnvironmentValue $workloads ([string] $consumer.workload) "Messaging__AzureServiceBus__Consumers__$($consumer.id)__Subscription" $subscriptionName
        }
        $topics += $topic
    }

    $configuration = [ordered] @{
        UserConfig = [ordered] @{
            Namespaces = @([ordered] @{ Name = 'sbemulatorns'; Queues = @(); Topics = $topics })
            Logging    = [ordered] @{ Type = 'File' }
        }
    }
    $compose = @'
services:
  mssql:
    image: mcr.microsoft.com/mssql/server:2022-CU14-ubuntu-22.04
    environment:
      ACCEPT_EULA: "${ACCEPT_EULA:-N}"
      MSSQL_SA_PASSWORD: "${MSSQL_SA_PASSWORD:?MSSQL_SA_PASSWORD is required}"
  servicebus:
    image: mcr.microsoft.com/azure-messaging/servicebus-emulator:2.0.0
    depends_on:
      - mssql
    environment:
      SQL_SERVER: mssql
      MSSQL_SA_PASSWORD: "${MSSQL_SA_PASSWORD:?MSSQL_SA_PASSWORD is required}"
      ACCEPT_EULA: "${ACCEPT_EULA:-N}"
      EMULATOR_HTTP_PORT: "5300"
    ports:
      - "5672:5672"
      - "5300:5300"
    volumes:
      - ./servicebus-config.json:/ServiceBus_Emulator/ConfigFiles/Config.json:ro
'@
    return [pscustomobject] @{
        Workloads = $workloads
        Files     = [ordered] @{
            'compose.yaml'             = $compose
            'servicebus-config.json'   = ($configuration | ConvertTo-Json -Depth 20)
        }
    }
}

function ConvertTo-AwsLocalMessaging {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Manifest,
        [AllowNull()]
        [pscustomobject] $Policy
    )

    $region = if ($null -eq $Policy) { 'us-east-1' } else { [string] $Policy.region }
    $accountId = '000000000000'
    $serviceUrl = 'http://localhost:4566'
    $workloads = [ordered] @{}
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('#!/bin/sh')
    $lines.Add('set -eu')
    $lines.Add('')

    foreach ($destination in $Manifest.destinations) {
        $policyDestination = Get-PolicyItem -Policy $Policy -Collection destinations -Id ([string] $destination.id)
        $topicName = if ($null -eq $policyDestination) { [string] $destination.id } else { [string] $policyDestination.topicName }
        $topicVariable = ([string] $destination.id).Replace('-', '_') + '_topic_arn'
        $lines.Add("$topicVariable=`$(awslocal sns create-topic --name '$topicName' --query TopicArn --output text)")

        foreach ($workload in $destination.publisherWorkloads) {
            Add-LocalEnvironmentValue $workloads ([string] $workload) 'AWS_ACCESS_KEY_ID' 'test'
            Add-LocalEnvironmentValue $workloads ([string] $workload) 'AWS_SECRET_ACCESS_KEY' 'test'
            Add-LocalEnvironmentValue $workloads ([string] $workload) 'AWS_REGION' $region
            Add-LocalEnvironmentValue $workloads ([string] $workload) "Messaging__Aws__Sns__Destinations__$($destination.id)__TopicArn" "arn:aws:sns:${region}:${accountId}:$topicName"
            Add-LocalEnvironmentValue $workloads ([string] $workload) "Messaging__Aws__Sns__Destinations__$($destination.id)__Region" $region
            Add-LocalEnvironmentValue $workloads ([string] $workload) "Messaging__Aws__Sns__Destinations__$($destination.id)__ServiceUrl" $serviceUrl
        }

        foreach ($consumer in @($Manifest.consumers | Where-Object { [string] $_.destination -ceq [string] $destination.id })) {
            $policyConsumer = Get-PolicyItem -Policy $Policy -Collection consumers -Id ([string] $consumer.id)
            $queueName = if ($null -eq $policyConsumer) { [string] $consumer.id } else { [string] $policyConsumer.queueName }
            $visibility = if ($null -eq $policyConsumer) { 30 } else { [int] $policyConsumer.visibilityTimeoutSeconds }
            $retention = if ($null -eq $policyConsumer) { 345600 } else { [int] $policyConsumer.messageRetentionSeconds }
            $waitTime = if ($null -eq $policyConsumer) { 1 } else { [int] $policyConsumer.receiveMessageWaitTimeSeconds }
            $retryVisibility = if ($null -eq $policyConsumer) { 0 } else { [int] $policyConsumer.retryVisibilityTimeoutSeconds }
            $queueVariable = ([string] $consumer.id).Replace('-', '_')
            $queueAttributes = '{' +
                '"VisibilityTimeout":"' + $visibility + '",' +
                '"MessageRetentionPeriod":"' + $retention + '",' +
                '"ReceiveMessageWaitTimeSeconds":"' + $waitTime + '"}'
            $lines.Add("${queueVariable}_attributes='$queueAttributes'")
            $redriveEnabled = $null -ne $policyConsumer -and [bool] $policyConsumer.redrive.enabled
            if ($redriveEnabled) {
                $dlqName = [string] $policyConsumer.redrive.deadLetterQueueName
                $dlqRetention = [int] $policyConsumer.redrive.deadLetterMessageRetentionSeconds
                $maxReceiveCount = [int] $policyConsumer.redrive.maxReceiveCount
                $lines.Add("${queueVariable}_dlq_attributes='{`"MessageRetentionPeriod`":`"$dlqRetention`"}'")
                $lines.Add("${queueVariable}_dlq_url=`$(awslocal sqs create-queue --queue-name '$dlqName' --attributes `"`$${queueVariable}_dlq_attributes`" --query QueueUrl --output text)")
                $lines.Add("${queueVariable}_dlq_arn=`$(awslocal sqs get-queue-attributes --queue-url `"`$${queueVariable}_dlq_url`" --attribute-names QueueArn --query Attributes.QueueArn --output text)")
                $lines.Add("${queueVariable}_redrive=`$(printf '{`"deadLetterTargetArn`":`"%s`",`"maxReceiveCount`":$maxReceiveCount}' `"`$${queueVariable}_dlq_arn`")")
                $lines.Add("${queueVariable}_redrive_attributes=`$(python3 -c 'import json,sys; print(json.dumps(dict(RedrivePolicy=sys.argv[1])))' `"`$${queueVariable}_redrive`")")
                $lines.Add("${queueVariable}_url=`$(awslocal sqs create-queue --queue-name '$queueName' --attributes `"`$${queueVariable}_attributes`" --query QueueUrl --output text)")
                $lines.Add("awslocal sqs set-queue-attributes --queue-url `"`$${queueVariable}_url`" --attributes `"`$${queueVariable}_redrive_attributes`"")
            }
            else {
                $lines.Add("${queueVariable}_url=`$(awslocal sqs create-queue --queue-name '$queueName' --attributes `"`$${queueVariable}_attributes`" --query QueueUrl --output text)")
            }
            $lines.Add("${queueVariable}_arn=`$(awslocal sqs get-queue-attributes --queue-url `"`$${queueVariable}_url`" --attribute-names QueueArn --query Attributes.QueueArn --output text)")
            $lines.Add("${queueVariable}_subscription=`$(awslocal sns subscribe --topic-arn `"`$$topicVariable`" --protocol sqs --notification-endpoint `"`$${queueVariable}_arn`" --attributes RawMessageDelivery=true --query SubscriptionArn --output text)")
            if ([string] $consumer.routing.mode -ceq 'include') {
                $eventTypes = @($consumer.routing.eventTypes | ForEach-Object { '"' + [string] $_ + '"' }) -join ','
                $filterPolicy = '{"EventType":[' + $eventTypes + ']}'
                $lines.Add("awslocal sns set-subscription-attributes --subscription-arn `"`$${queueVariable}_subscription`" --attribute-name FilterPolicy --attribute-value '$filterPolicy'")
            }
            $lines.Add('')

            Add-LocalEnvironmentValue $workloads ([string] $consumer.workload) 'AWS_ACCESS_KEY_ID' 'test'
            Add-LocalEnvironmentValue $workloads ([string] $consumer.workload) 'AWS_SECRET_ACCESS_KEY' 'test'
            Add-LocalEnvironmentValue $workloads ([string] $consumer.workload) 'AWS_REGION' $region
            Add-LocalEnvironmentValue $workloads ([string] $consumer.workload) "Messaging__Aws__Sqs__Consumers__$($consumer.id)__QueueUrl" "$serviceUrl/$accountId/$queueName"
            Add-LocalEnvironmentValue $workloads ([string] $consumer.workload) "Messaging__Aws__Sqs__Consumers__$($consumer.id)__Region" $region
            Add-LocalEnvironmentValue $workloads ([string] $consumer.workload) "Messaging__Aws__Sqs__Consumers__$($consumer.id)__ServiceUrl" $serviceUrl
            Add-LocalEnvironmentValue $workloads ([string] $consumer.workload) "Messaging__Aws__Sqs__Consumers__$($consumer.id)__WaitTimeSeconds" ([string] $waitTime)
            Add-LocalEnvironmentValue $workloads ([string] $consumer.workload) "Messaging__Aws__Sqs__Consumers__$($consumer.id)__RetryVisibilityTimeoutSeconds" ([string] $retryVisibility)
        }
    }

    $compose = @'
services:
  localstack:
    image: localstack/localstack:4.9.2
    environment:
      SERVICES: sns,sqs
      AWS_DEFAULT_REGION: us-east-1
      AWS_ACCESS_KEY_ID: test
      AWS_SECRET_ACCESS_KEY: test
      SQS_ENDPOINT_STRATEGY: path
    ports:
      - "4566:4566"
    volumes:
      - ./localstack-init.sh:/etc/localstack/init/ready.d/init-aws.sh:ro
'@
    return [pscustomobject] @{
        Workloads = $workloads
        Files     = [ordered] @{
            'compose.yaml'       = $compose.Replace('AWS_DEFAULT_REGION: us-east-1', "AWS_DEFAULT_REGION: $region")
            'localstack-init.sh' = ($lines -join "`n")
        }
    }
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

function New-LocalMessagingPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Manifest,
        [AllowNull()]
        [pscustomobject] $Policy
    )

    if ($null -ne $Policy) {
        Assert-LocalMessagingPolicy -Manifest $Manifest -Policy $Policy
    }
    $providerPlan = switch ([string] $Manifest.provider) {
        'azure-service-bus' { ConvertTo-AzureLocalMessaging -Manifest $Manifest -Policy $Policy }
        'aws-sns-sqs' { ConvertTo-AwsLocalMessaging -Manifest $Manifest -Policy $Policy }
        'rabbitmq' { ConvertTo-RabbitMqLocalMessaging -Manifest $Manifest -Policy $Policy }
        default { throw "Unsupported messaging provider '$($Manifest.provider)'." }
    }
    $bindings = [ordered] @{
        apiVersion = 'hexagon.ec/local-messaging-bindings/v1'
        kind       = 'LocalMessagingBindings'
        product    = [string] $Manifest.product
        provider   = [string] $Manifest.provider
        workloads  = $providerPlan.Workloads
    }
    return [pscustomobject] @{
        Bindings = $bindings
        Files    = $providerPlan.Files
    }
}

Export-ModuleMember -Function @(
    'Assert-LocalMessagingPolicy',
    'Get-LocalMessagingManifest',
    'New-LocalMessagingPlan'
)
