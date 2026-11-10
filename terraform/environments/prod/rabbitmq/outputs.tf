output "messaging_bindings" {
  description = "Non-secret RabbitMQ settings grouped by workload."
  value       = module.messaging.workload_bindings
}

output "messaging_connection_requirements" {
  description = "RabbitMQ users, virtual host and secret setting keys grouped by workload."
  value       = module.messaging.workload_connection_requirements
}

output "messaging_topology" {
  description = "Physical RabbitMQ destination and consumer mappings."
  value = {
    virtual_host = module.messaging.virtual_host
    destinations = module.messaging.destinations
    consumers    = module.messaging.consumers
  }
}
