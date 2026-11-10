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

function Test-AwsSnsSqsPolicyModel {
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

    $queueNames = [Collections.Generic.List[string]]::new()
    foreach ($consumer in $Policy.consumers) {
        $queueNames.Add([string] $consumer.queueName)
        if ([bool] $consumer.redrive.enabled) {
            $queueNames.Add([string] $consumer.redrive.deadLetterQueueName)
            if ([int] $consumer.redrive.deadLetterMessageRetentionSeconds -le
                [int] $consumer.messageRetentionSeconds) {
                throw "Consumer '$($consumer.id)' dead-letter retention must be longer than its source queue retention."
            }
        }
    }
    $duplicateQueueNames = @(Get-DuplicateValues -Values $queueNames.ToArray())
    if ($duplicateQueueNames.Count -gt 0) {
        throw "Duplicate source or dead-letter queue names: $($duplicateQueueNames -join ', ')."
    }
}

function ConvertTo-AwsSnsSqsTerraformInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Descriptor,

        [Parameter(Mandatory = $true)]
        [psobject] $Policy,

        [Parameter(Mandatory = $true)]
        [psobject] $Manifest
    )

    Test-AwsSnsSqsPolicyModel -Policy $Policy

    if ([string] $Policy.product -cne [string] $Descriptor.product -or
        [string] $Policy.product -cne [string] $Manifest.product) {
        throw 'The descriptor, policy, and backend manifest must declare the same product.'
    }
    if ([string] $Policy.environment -cne [string] $Descriptor.environment) {
        throw 'The descriptor and AWS SNS/SQS policy must declare the same environment.'
    }
    if ([string] $Manifest.provider -cne 'aws-sns-sqs') {
        throw "Backend messaging provider '$($Manifest.provider)' is not aws-sns-sqs."
    }

    $manifestDestinationIds = @($Manifest.destinations | ForEach-Object { [string] $_.id })
    $duplicateManifestDestinations = @(Get-DuplicateValues -Values $manifestDestinationIds)
    if ($duplicateManifestDestinations.Count -gt 0) {
        throw "Backend manifest repeats destinations: $($duplicateManifestDestinations -join ', ')."
    }
    $policyDestinationIds = @($Policy.destinations | ForEach-Object { [string] $_.id })
    Assert-SameValues `
        -Label 'AWS SNS/SQS policy destinations' `
        -Expected $manifestDestinationIds `
        -Actual $policyDestinationIds

    $manifestConsumerIds = @($Manifest.consumers | ForEach-Object { [string] $_.id })
    $duplicateManifestConsumers = @(Get-DuplicateValues -Values $manifestConsumerIds)
    if ($duplicateManifestConsumers.Count -gt 0) {
        throw "Backend manifest repeats consumers: $($duplicateManifestConsumers -join ', ')."
    }
    $policyConsumerIds = @($Policy.consumers | ForEach-Object { [string] $_.id })
    Assert-SameValues `
        -Label 'AWS SNS/SQS policy consumers' `
        -Expected $manifestConsumerIds `
        -Actual $policyConsumerIds

    $requiredWorkloads = @(
        @($Manifest.destinations.publisherWorkloads) +
        @($Manifest.consumers.workload) |
            ForEach-Object { [string] $_ } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
    $roleProperties = @($Policy.workloadRoleNames.PSObject.Properties)
    $roleWorkloads = @($roleProperties | ForEach-Object Name)
    Assert-SameValues `
        -Label 'AWS SNS/SQS workload role names' `
        -Expected $requiredWorkloads `
        -Actual $roleWorkloads
    $duplicateRoleNames = @(
        Get-DuplicateValues -Values @($roleProperties | ForEach-Object { [string] $_.Value })
    )
    if ($duplicateRoleNames.Count -gt 0) {
        throw 'Each messaging workload must use a distinct IAM role to preserve least privilege.'
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
            $publishers[[string] $workload] = [string] $Policy.workloadRoleNames.$workload
        }

        $destinations[$destinationId] = [ordered] @{
            name        = [string] $physical.topicName
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
        $redrive = [ordered] @{
            enabled = [bool] $physical.redrive.enabled
        }
        if ($redrive.enabled) {
            $redrive.dead_letter_queue_name = [string] $physical.redrive.deadLetterQueueName
            $redrive.max_receive_count = [int] $physical.redrive.maxReceiveCount
            $redrive.dead_letter_message_retention_seconds =
                [int] $physical.redrive.deadLetterMessageRetentionSeconds
        }

        $consumers[$consumerId] = [ordered] @{
            name                                = [string] $physical.queueName
            destination                         = $destinationId
            workload                            = $workload
            role_name                           = [string] $Policy.workloadRoleNames.$workload
            routing_mode                        = $routingMode
            event_types                         = $eventTypes
            visibility_timeout_seconds          = [int] $physical.visibilityTimeoutSeconds
            message_retention_seconds           = [int] $physical.messageRetentionSeconds
            receive_message_wait_time_seconds   = [int] $physical.receiveMessageWaitTimeSeconds
            retry_visibility_timeout_seconds    = [int] $physical.retryVisibilityTimeoutSeconds
            redrive                             = $redrive
        }
    }

    $tags = [ordered] @{}
    if ($Policy.PSObject.Properties.Name -ccontains 'tags') {
        foreach ($tag in @($Policy.tags.PSObject.Properties | Sort-Object Name)) {
            $tags[$tag.Name] = [string] $tag.Value
        }
    }

    return [ordered] @{
        product      = [string] $Policy.product
        environment  = [string] $Policy.environment
        region       = [string] $Policy.region
        kms_alias_name = [string] $Policy.kmsAliasName
        tags         = $tags
        destinations = $destinations
        consumers    = $consumers
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-AwsSnsSqsTerraformInput',
    'Test-AwsSnsSqsPolicyModel'
)
