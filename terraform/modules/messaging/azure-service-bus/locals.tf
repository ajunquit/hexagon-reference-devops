locals {
  namespace_fully_qualified_name = "${var.namespace.name}.servicebus.windows.net"

  included_event_rules = {
    for rule in flatten([
      for consumer_id, consumer in var.consumers : [
        for event_type in consumer.event_types : {
          key         = "${consumer_id}/${event_type}"
          consumer_id = consumer_id
          event_type  = event_type
        }
      ] if consumer.routing_mode == "include"
    ]) : rule.key => rule
  }

  all_event_rules = {
    for consumer_id, consumer in var.consumers : consumer_id => consumer
    if consumer.routing_mode == "all"
  }

  sender_assignments = {
    for assignment in flatten([
      for destination_id, destination in var.destinations : [
        for workload, principal_id in destination.publishers : {
          key            = "${destination_id}/${workload}"
          destination_id = destination_id
          workload       = workload
          principal_id   = principal_id
        }
      ]
    ]) : assignment.key => assignment
  }

  publisher_binding_fragments = flatten([
    for destination_id, destination in var.destinations : [
      for workload in keys(destination.publishers) : {
        workload = workload
        values = {
          "Messaging__AzureServiceBus__Destinations__${destination_id}__Topic" = destination.name
        }
      }
    ]
  ])

  consumer_binding_fragments = [
    for consumer_id, consumer in var.consumers : {
      workload = consumer.workload
      values = {
        "Messaging__AzureServiceBus__Consumers__${consumer_id}__Topic"        = var.destinations[consumer.destination].name
        "Messaging__AzureServiceBus__Consumers__${consumer_id}__Subscription" = consumer.name
      }
    }
  ]

  workload_names = toset(concat(
    [for binding in local.publisher_binding_fragments : binding.workload],
    [for binding in local.consumer_binding_fragments : binding.workload]
  ))

  workload_bindings = {
    for workload in local.workload_names : workload => merge(
      { "ConnectionStrings__servicebus" = local.namespace_fully_qualified_name },
      [for binding in concat(local.publisher_binding_fragments, local.consumer_binding_fragments) :
        binding.values if binding.workload == workload
      ]...
    )
  }
}
