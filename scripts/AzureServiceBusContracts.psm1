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

function ConvertFrom-IsoDuration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Value,

        [Parameter(Mandatory = $true)]
        [string] $Label
    )

    try {
        return [Xml.XmlConvert]::ToTimeSpan($Value)
    }
    catch {
        throw "$Label '$Value' is not a valid ISO 8601 duration."
    }
}

function Test-AzureServiceBusPolicyModel {
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

    $topicNames = @($Policy.destinations | ForEach-Object { [string] $_.topicName })
    $duplicateTopicNames = @(Get-DuplicateValues -Values $topicNames)
    if ($duplicateTopicNames.Count -gt 0) {
        throw "Duplicate topic names: $($duplicateTopicNames -join ', ')."
    }

    $consumerIds = @($Policy.consumers | ForEach-Object { [string] $_.id })
    $duplicateConsumerIds = @(Get-DuplicateValues -Values $consumerIds)
    if ($duplicateConsumerIds.Count -gt 0) {
        throw "Duplicate consumer ids: $($duplicateConsumerIds -join ', ')."
    }

    foreach ($destination in $Policy.destinations) {
        $ttl = ConvertFrom-IsoDuration `
            -Value ([string] $destination.defaultMessageTtl) `
            -Label "Destination '$($destination.id)' defaultMessageTtl"
        if ($ttl -le [TimeSpan]::Zero) {
            throw "Destination '$($destination.id)' defaultMessageTtl must be positive."
        }

        $history = ConvertFrom-IsoDuration `
            -Value ([string] $destination.duplicateDetectionHistory) `
            -Label "Destination '$($destination.id)' duplicateDetectionHistory"
        if ($history -lt [TimeSpan]::FromSeconds(20) -or $history -gt [TimeSpan]::FromDays(7)) {
            throw "Destination '$($destination.id)' duplicateDetectionHistory must be between 20 seconds and 7 days."
        }
    }

    foreach ($consumer in $Policy.consumers) {
        $lock = ConvertFrom-IsoDuration `
            -Value ([string] $consumer.lockDuration) `
            -Label "Consumer '$($consumer.id)' lockDuration"
        if ($lock -lt [TimeSpan]::FromSeconds(5) -or $lock -gt [TimeSpan]::FromMinutes(5)) {
            throw "Consumer '$($consumer.id)' lockDuration must be between 5 seconds and 5 minutes."
        }

        $ttl = ConvertFrom-IsoDuration `
            -Value ([string] $consumer.defaultMessageTtl) `
            -Label "Consumer '$($consumer.id)' defaultMessageTtl"
        if ($ttl -le [TimeSpan]::Zero) {
            throw "Consumer '$($consumer.id)' defaultMessageTtl must be positive."
        }
    }
}

function ConvertTo-AzureServiceBusTerraformInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Descriptor,

        [Parameter(Mandatory = $true)]
        [psobject] $Policy,

        [Parameter(Mandatory = $true)]
        [psobject] $Manifest
    )

    Test-AzureServiceBusPolicyModel -Policy $Policy

    if ([string] $Policy.product -cne [string] $Descriptor.product -or
        [string] $Policy.product -cne [string] $Manifest.product) {
        throw 'The descriptor, policy, and backend manifest must declare the same product.'
    }
    if ([string] $Policy.environment -cne [string] $Descriptor.environment) {
        throw 'The descriptor and Azure Service Bus policy must declare the same environment.'
    }
    if ([string] $Manifest.provider -cne 'azure-service-bus') {
        throw "Backend messaging provider '$($Manifest.provider)' is not azure-service-bus."
    }

    $manifestDestinationIds = @($Manifest.destinations | ForEach-Object { [string] $_.id })
    $duplicateManifestDestinations = @(Get-DuplicateValues -Values $manifestDestinationIds)
    if ($duplicateManifestDestinations.Count -gt 0) {
        throw "Backend manifest repeats destinations: $($duplicateManifestDestinations -join ', ')."
    }
    $policyDestinationIds = @($Policy.destinations | ForEach-Object { [string] $_.id })
    Assert-SameValues `
        -Label 'Azure Service Bus policy destinations' `
        -Expected $manifestDestinationIds `
        -Actual $policyDestinationIds

    $manifestConsumerIds = @($Manifest.consumers | ForEach-Object { [string] $_.id })
    $duplicateManifestConsumers = @(Get-DuplicateValues -Values $manifestConsumerIds)
    if ($duplicateManifestConsumers.Count -gt 0) {
        throw "Backend manifest repeats consumers: $($duplicateManifestConsumers -join ', ')."
    }
    $policyConsumerIds = @($Policy.consumers | ForEach-Object { [string] $_.id })
    Assert-SameValues `
        -Label 'Azure Service Bus policy consumers' `
        -Expected $manifestConsumerIds `
        -Actual $policyConsumerIds

    $requiredWorkloads = @(
        @($Manifest.destinations.publisherWorkloads) +
        @($Manifest.consumers.workload) |
            ForEach-Object { [string] $_ } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
    $principalProperties = @($Policy.workloadPrincipalIds.PSObject.Properties)
    $principalWorkloads = @($principalProperties | ForEach-Object Name)
    Assert-SameValues `
        -Label 'Azure Service Bus workload principal ids' `
        -Expected $requiredWorkloads `
        -Actual $principalWorkloads
    $duplicatePrincipalIds = @(
        Get-DuplicateValues -Values @($principalProperties | ForEach-Object { [string] $_.Value })
    )
    if ($duplicatePrincipalIds.Count -gt 0) {
        throw 'Each messaging workload must use a distinct principal id to preserve least privilege.'
    }

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
            $publishers[[string] $workload] = [string] $Policy.workloadPrincipalIds.$workload
        }

        $destinations[$destinationId] = [ordered] @{
            name                                        = [string] $physical.topicName
            default_message_ttl                         = [string] $physical.defaultMessageTtl
            duplicate_detection_enabled                 = [bool] $physical.duplicateDetectionEnabled
            duplicate_detection_history_time_window     = [string] $physical.duplicateDetectionHistory
            event_types                                 = @($destination.eventTypes | Sort-Object)
            publishers                                  = $publishers
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
        $consumers[$consumerId] = [ordered] @{
            name                              = [string] $physical.subscriptionName
            destination                       = $destinationId
            workload                          = $workload
            principal_id                      = [string] $Policy.workloadPrincipalIds.$workload
            routing_mode                      = $routingMode
            event_types                       = $eventTypes
            max_delivery_count                = [int] $physical.maxDeliveryCount
            lock_duration                     = [string] $physical.lockDuration
            default_message_ttl               = [string] $physical.defaultMessageTtl
            dead_letter_on_message_expiration = [bool] $physical.deadLetterOnMessageExpiration
        }
    }

    $subscriptionEntityKeys = @(
        $consumers.GetEnumerator() | ForEach-Object {
            "$($_.Value.destination)/$($_.Value.name)"
        }
    )
    $duplicateSubscriptionEntities = @(
        Get-DuplicateValues -Values $subscriptionEntityKeys
    )
    if ($duplicateSubscriptionEntities.Count -gt 0) {
        throw "Duplicate subscriptions within a topic: $($duplicateSubscriptionEntities -join ', ')."
    }

    $namespace = [ordered] @{
        name                          = [string] $Policy.namespace.name
        sku                           = [string] $Policy.namespace.sku
        public_network_access_enabled = [bool] $Policy.namespace.publicNetworkAccessEnabled
    }
    if ($Policy.namespace.PSObject.Properties.Name -ccontains 'capacity') {
        $namespace.capacity = [int] $Policy.namespace.capacity
    }

    $tags = [ordered] @{}
    if ($Policy.PSObject.Properties.Name -ccontains 'tags') {
        foreach ($tag in @($Policy.tags.PSObject.Properties | Sort-Object Name)) {
            $tags[$tag.Name] = [string] $tag.Value
        }
    }

    return [ordered] @{
        product             = [string] $Policy.product
        environment         = [string] $Policy.environment
        location            = [string] $Policy.location
        resource_group_name = [string] $Policy.resourceGroupName
        tags                = $tags
        namespace           = $namespace
        destinations        = $destinations
        consumers           = $consumers
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-AzureServiceBusTerraformInput',
    'Test-AzureServiceBusPolicyModel'
)
