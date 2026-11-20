# Export fixture of Azure Service Bus for tests/Test-MessagingOperationsExport.ps1: completes the shared operations
# policy for the provider and returns the Terraform outputs of its physical topology.
return {
    param($policy, $topology, $mapping)
    $policy.notificationTargets = @('/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-example/providers/Microsoft.Insights/actionGroups/example')
    $policy.operatorIdentities.worker = '00000000-0000-0000-0000-000000000011'
    $policy.operatorIdentities.'sales-worker' = '00000000-0000-0000-0000-000000000012'
    $policy.consumers[0].deadLetterThreshold = 1
    $policy.consumers[0].quarantineReviewHours = 24
    $mapping.namespace = @{ name = $topology.namespace.name }
    foreach ($consumer in $topology.consumers) { $mapping.consumers[$consumer.id] = @{ name = $consumer.subscriptionName; topic_name = $topology.destinations[0].topicName } }
    $outputs = @{ azure_service_bus = @{ value = $mapping } }
    return $outputs
}
