Set-StrictMode -Version Latest

function Get-DuplicateValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Values
    )

    return @(
        $Values |
            Group-Object -CaseSensitive |
            Where-Object Count -gt 1 |
            ForEach-Object Name
    )
}

function Assert-SameValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Label,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Expected,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Actual
    )

    $missing = @($Expected | Where-Object { $_ -cnotin $Actual } | Sort-Object)
    $unexpected = @($Actual | Where-Object { $_ -cnotin $Expected } | Sort-Object)
    if ($missing.Count -gt 0 -or $unexpected.Count -gt 0) {
        $parts = [Collections.Generic.List[string]]::new()
        if ($missing.Count -gt 0) {
            $parts.Add("missing: $($missing -join ', ')")
        }
        if ($unexpected.Count -gt 0) {
            $parts.Add("unexpected: $($unexpected -join ', ')")
        }
        throw "$Label do not match the backend contract ($($parts -join '; '))."
    }
}

function Test-RabbitMqPolicyModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Policy
    )

    $destinationIds = @($Policy.destinations | ForEach-Object { [string] $_.id })
    $duplicateDestinationIds = @(Get-DuplicateValues -Values $destinationIds)
    if ($duplicateDestinationIds.Count -gt 0) {
        throw "Duplicate destination ids: $($duplicateDestinationIds -join ', ')."
    }

    $consumerIds = @($Policy.consumers | ForEach-Object { [string] $_.id })
    $duplicateConsumerIds = @(Get-DuplicateValues -Values $consumerIds)
    if ($duplicateConsumerIds.Count -gt 0) {
        throw "Duplicate consumer ids: $($duplicateConsumerIds -join ', ')."
    }

    $exchangeNames = [Collections.Generic.List[string]]::new()
    foreach ($destination in $Policy.destinations) {
        $exchangeNames.Add([string] $destination.exchangeName)
    }

    $queueNames = [Collections.Generic.List[string]]::new()
    foreach ($consumer in $Policy.consumers) {
        $queueNames.Add([string] $consumer.queueName)
        if ([bool] $consumer.deadLetter.enabled) {
            $exchangeNames.Add([string] $consumer.deadLetter.exchangeName)
            $queueNames.Add([string] $consumer.deadLetter.queueName)
        }
    }

    $duplicateExchangeNames = @(Get-DuplicateValues -Values $exchangeNames.ToArray())
    if ($duplicateExchangeNames.Count -gt 0) {
        throw "Duplicate destination or dead-letter exchange names: $($duplicateExchangeNames -join ', ')."
    }

    $duplicateQueueNames = @(Get-DuplicateValues -Values $queueNames.ToArray())
    if ($duplicateQueueNames.Count -gt 0) {
        throw "Duplicate source or dead-letter queue names: $($duplicateQueueNames -join ', ')."
    }

    $userNames = @(
        $Policy.workloadUserNames.PSObject.Properties |
            ForEach-Object { [string] $_.Value }
    )
    $duplicateUserNames = @(Get-DuplicateValues -Values $userNames)
    if ($duplicateUserNames.Count -gt 0) {
        throw 'Each messaging workload must use a distinct RabbitMQ user to preserve least privilege.'
    }
}

function ConvertTo-RabbitMqTerraformInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Descriptor,

        [Parameter(Mandatory = $true)]
        [psobject] $Policy,

        [Parameter(Mandatory = $true)]
        [psobject] $Manifest
    )

    Test-RabbitMqPolicyModel -Policy $Policy

    if ([string] $Policy.product -cne [string] $Descriptor.product -or
        [string] $Policy.product -cne [string] $Manifest.product) {
        throw 'The descriptor, policy, and backend manifest must declare the same product.'
    }
    if ([string] $Policy.environment -cne [string] $Descriptor.environment) {
        throw 'The descriptor and RabbitMQ policy must declare the same environment.'
    }
    if ([string] $Manifest.provider -cne 'rabbitmq') {
        throw "Backend messaging provider '$($Manifest.provider)' is not rabbitmq."
    }

    $manifestDestinationIds = @($Manifest.destinations | ForEach-Object { [string] $_.id })
    $duplicateManifestDestinations = @(Get-DuplicateValues -Values $manifestDestinationIds)
    if ($duplicateManifestDestinations.Count -gt 0) {
        throw "Backend manifest repeats destinations: $($duplicateManifestDestinations -join ', ')."
    }
    $policyDestinationIds = @($Policy.destinations | ForEach-Object { [string] $_.id })
    Assert-SameValues `
        -Label 'RabbitMQ policy destinations' `
        -Expected $manifestDestinationIds `
        -Actual $policyDestinationIds

    $manifestConsumerIds = @($Manifest.consumers | ForEach-Object { [string] $_.id })
    $duplicateManifestConsumers = @(Get-DuplicateValues -Values $manifestConsumerIds)
    if ($duplicateManifestConsumers.Count -gt 0) {
        throw "Backend manifest repeats consumers: $($duplicateManifestConsumers -join ', ')."
    }
    $policyConsumerIds = @($Policy.consumers | ForEach-Object { [string] $_.id })
    Assert-SameValues `
        -Label 'RabbitMQ policy consumers' `
        -Expected $manifestConsumerIds `
        -Actual $policyConsumerIds

    $requiredWorkloads = @(
        @($Manifest.destinations.publisherWorkloads) +
        @($Manifest.consumers.workload) |
            ForEach-Object { [string] $_ } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
    $userProperties = @($Policy.workloadUserNames.PSObject.Properties)
    $userWorkloads = @($userProperties | ForEach-Object Name)
    Assert-SameValues `
        -Label 'RabbitMQ workload user names' `
        -Expected $requiredWorkloads `
        -Actual $userWorkloads

    $policyDestinations = @{}
    foreach ($destination in $Policy.destinations) {
        $policyDestinations[[string] $destination.id] = $destination
    }
    $policyConsumers = @{}
    foreach ($consumer in $Policy.consumers) {
        $policyConsumers[[string] $consumer.id] = $consumer
    }

    $destinations = [ordered] @{}
    foreach ($destination in @($Manifest.destinations | Sort-Object id)) {
        $destinationId = [string] $destination.id
        $physical = $policyDestinations[$destinationId]
        $publishers = [ordered] @{}
        foreach ($workload in @($destination.publisherWorkloads | Sort-Object)) {
            $publishers[[string] $workload] = [string] $Policy.workloadUserNames.$workload
        }

        $destinations[$destinationId] = [ordered] @{
            name        = [string] $physical.exchangeName
            event_types = @($destination.eventTypes | Sort-Object)
            publishers  = $publishers
        }
    }

    $consumers = [ordered] @{}
    foreach ($consumer in @($Manifest.consumers | Sort-Object id)) {
        $consumerId = [string] $consumer.id
        $destinationId = [string] $consumer.destination
        if ($destinationId -cnotin $manifestDestinationIds) {
            throw "Consumer '$consumerId' references unknown destination '$destinationId'."
        }

        $publishedEventTypes = @(
            $Manifest.destinations |
                Where-Object { [string] $_.id -ceq $destinationId } |
                ForEach-Object eventTypes
        )
        $routingMode = [string] $consumer.routing.mode
        [string[]] $eventTypes = @()
        if ($routingMode -ceq 'include') {
            $eventTypes = @($consumer.routing.eventTypes | Sort-Object)
        }
        $unknownEventTypes = @($eventTypes | Where-Object { $_ -cnotin $publishedEventTypes })
        if ($unknownEventTypes.Count -gt 0) {
            throw "Consumer '$consumerId' routes event types not published by '$destinationId': $($unknownEventTypes -join ', ')."
        }

        $physical = $policyConsumers[$consumerId]
        $workload = [string] $consumer.workload
        $deadLetter = [ordered] @{
            enabled = [bool] $physical.deadLetter.enabled
        }
        if ($deadLetter.enabled) {
            $deadLetter.exchange_name = [string] $physical.deadLetter.exchangeName
            $deadLetter.queue_name = [string] $physical.deadLetter.queueName
            $deadLetter.routing_key = [string] $physical.deadLetter.routingKey
        }

        $consumers[$consumerId] = [ordered] @{
            name           = [string] $physical.queueName
            destination    = $destinationId
            workload       = $workload
            user_name      = [string] $Policy.workloadUserNames.$workload
            routing_mode   = $routingMode
            event_types    = $eventTypes
            delivery_limit = [int] $physical.deliveryLimit
            dead_letter    = $deadLetter
        }
    }

    return [ordered] @{
        virtual_host = [string] $Policy.virtualHost
        destinations = $destinations
        consumers    = $consumers
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-RabbitMqTerraformInput',
    'Test-RabbitMqPolicyModel'
)
