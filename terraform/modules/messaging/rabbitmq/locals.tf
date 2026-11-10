locals {
  dead_letter_consumers = {
    for consumer_id, consumer in var.consumers : consumer_id => consumer
    if consumer.dead_letter.enabled
  }

  all_exchange_names = concat(
    [for destination in values(var.destinations) : destination.name],
    [for consumer in values(local.dead_letter_consumers) : consumer.dead_letter.exchange_name]
  )

  all_queue_names = concat(
    [for consumer in values(var.consumers) : consumer.name],
    [for consumer in values(local.dead_letter_consumers) : consumer.dead_letter.queue_name]
  )

  route_bindings = {
    for binding in flatten([
      for consumer_id, consumer in var.consumers : [
        for routing_key in consumer.routing_mode == "all" ? ["#"] : sort(tolist(consumer.event_types)) : {
          key            = "${consumer_id}/${routing_key}"
          consumer_id    = consumer_id
          destination_id = consumer.destination
          routing_key    = routing_key
        }
      ]
    ]) : binding.key => binding
  }

  publisher_assignments = flatten([
    for destination_id, destination in var.destinations : [
      for workload, user_name in destination.publishers : {
        destination_id = destination_id
        workload       = workload
        user_name      = user_name
      }
    ]
  ])

  consumer_assignments = [
    for consumer_id, consumer in var.consumers : {
      consumer_id = consumer_id
      workload    = consumer.workload
      user_name   = consumer.user_name
    }
  ]

  workload_names = toset(concat(
    [for assignment in local.publisher_assignments : assignment.workload],
    [for assignment in local.consumer_assignments : assignment.workload]
  ))

  workload_user_candidates = {
    for workload in local.workload_names : workload => distinct(concat(
      [for assignment in local.publisher_assignments : assignment.user_name if assignment.workload == workload],
      [for assignment in local.consumer_assignments : assignment.user_name if assignment.workload == workload]
    ))
  }

  workload_users = {
    for workload, candidates in local.workload_user_candidates : workload => candidates[0]
  }

  workload_exchange_names = {
    for workload in local.workload_names : workload => distinct([
      for assignment in local.publisher_assignments :
      var.destinations[assignment.destination_id].name if assignment.workload == workload
    ])
  }

  workload_queue_names = {
    for workload in local.workload_names : workload => distinct([
      for assignment in local.consumer_assignments :
      var.consumers[assignment.consumer_id].name if assignment.workload == workload
    ])
  }

  workload_permissions = {
    for workload, user_name in local.workload_users : workload => {
      user_name = user_name
      write = length(local.workload_exchange_names[workload]) > 0 ? "^(${join("|", [
        for name in local.workload_exchange_names[workload] : replace(name, ".", "\\.")
      ])})$" : "^$"
      read = length(local.workload_queue_names[workload]) > 0 ? "^(${join("|", [
        for name in local.workload_queue_names[workload] : replace(name, ".", "\\.")
      ])})$" : "^$"
    }
  }

  publisher_destinations_by_workload = {
    for workload in local.workload_names : workload => {
      for assignment in local.publisher_assignments : assignment.destination_id => {
        exchange_name = var.destinations[assignment.destination_id].name
        event_types   = var.destinations[assignment.destination_id].event_types
      } if assignment.workload == workload
    }
    if length([for assignment in local.publisher_assignments : assignment if assignment.workload == workload]) > 0
  }

  publisher_binding_fragments = flatten([
    for destination_id, destination in var.destinations : [
      for workload in keys(destination.publishers) : {
        workload = workload
        values = {
          "Messaging__RabbitMq__Destinations__${destination_id}__Exchange" = rabbitmq_exchange.destination[destination_id].name
        }
        connection_key = "Messaging__RabbitMq__Destinations__${destination_id}__ConnectionString"
      }
    ]
  ])

  consumer_binding_fragments = [
    for consumer_id, consumer in var.consumers : {
      workload = consumer.workload
      values = {
        "Messaging__RabbitMq__Consumers__${consumer_id}__Exchange" = rabbitmq_exchange.destination[consumer.destination].name
        "Messaging__RabbitMq__Consumers__${consumer_id}__Queue"    = rabbitmq_queue.consumer[consumer_id].name
      }
      connection_key = "Messaging__RabbitMq__Consumers__${consumer_id}__ConnectionString"
    }
  ]

  all_binding_fragments = concat(local.publisher_binding_fragments, local.consumer_binding_fragments)

  workload_bindings = {
    for workload in local.workload_names : workload => merge([
      for binding in local.all_binding_fragments : binding.values if binding.workload == workload
    ]...)
  }

  workload_connection_requirements = {
    for workload in local.workload_names : workload => {
      user_name    = local.workload_users[workload]
      virtual_host = rabbitmq_vhost.this.name
      setting_keys = sort([
        for binding in local.all_binding_fragments : binding.connection_key if binding.workload == workload
      ])
    }
  }
}
