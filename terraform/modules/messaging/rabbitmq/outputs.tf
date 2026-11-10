output "virtual_host" {
  description = "Dedicated RabbitMQ virtual host."
  value       = rabbitmq_vhost.this.name
}

output "destinations" {
  description = "Physical topic exchange mapping by logical destination."
  value = {
    for destination_id, exchange in rabbitmq_exchange.destination : destination_id => {
      name = exchange.name
      type = "topic"
    }
  }
}

output "consumers" {
  description = "Physical quorum queue and optional dead-letter mapping by logical consumer."
  value = {
    for consumer_id, queue in rabbitmq_queue.consumer : consumer_id => {
      name           = queue.name
      delivery_limit = var.consumers[consumer_id].delivery_limit
      dead_letter = var.consumers[consumer_id].dead_letter.enabled ? {
        exchange_name = rabbitmq_exchange.dead_letter[consumer_id].name
        queue_name    = rabbitmq_queue.dead_letter[consumer_id].name
        routing_key   = var.consumers[consumer_id].dead_letter.routing_key
      } : null
    }
  }
}

output "workload_bindings" {
  description = "Non-secret environment settings to inject into each publisher or consumer workload."
  value       = local.workload_bindings
}

output "workload_connection_requirements" {
  description = "Existing users, virtual host and secret setting keys required from the deployment secret manager."
  value       = local.workload_connection_requirements
}
