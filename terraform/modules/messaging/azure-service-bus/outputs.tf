output "namespace" {
  description = "Namespace identifiers needed by deployment composition."
  value = {
    id                   = azurerm_servicebus_namespace.this.id
    name                 = azurerm_servicebus_namespace.this.name
    fully_qualified_name = local.namespace_fully_qualified_name
  }
}

output "destinations" {
  description = "Physical topic mapping by logical destination."
  value = {
    for destination_id, topic in azurerm_servicebus_topic.this : destination_id => {
      id   = topic.id
      name = topic.name
    }
  }
}

output "consumers" {
  description = "Physical subscription and dead-letter mapping by logical consumer."
  value = {
    for consumer_id, subscription in azurerm_servicebus_subscription.this : consumer_id => {
      id               = subscription.id
      name             = subscription.name
      topic_name       = var.destinations[var.consumers[consumer_id].destination].name
      dead_letter_path = "${var.destinations[var.consumers[consumer_id].destination].name}/Subscriptions/${subscription.name}/$DeadLetterQueue"
    }
  }
}

output "workload_bindings" {
  description = "Non-secret environment settings to inject into each publisher or consumer workload."
  value       = local.workload_bindings
}
