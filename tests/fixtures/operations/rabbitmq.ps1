# Export fixture of RabbitMQ for tests/Test-MessagingOperationsExport.ps1: completes the shared operations
# policy for the provider and returns the Terraform outputs of its physical topology.
return {
    param($policy, $topology, $mapping)
    $policy.notificationTargets = @()
    $mapping.virtual_host = $topology.virtualHost
    foreach ($consumer in $topology.consumers) {
        $queue = @{ name = $consumer.queueName }
        if ($consumer.deadLetter.enabled) { $queue.dead_letter = @{ queue_name = $consumer.deadLetter.queueName } }
        $mapping.consumers[$consumer.id] = $queue
    }
    $outputs = @{ messaging_topology = @{ value = $mapping } }
    return $outputs
}
