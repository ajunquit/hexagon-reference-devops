check "consumer_destinations" {
  assert {
    condition = alltrue([
      for consumer in values(var.consumers) : contains(keys(var.destinations), consumer.destination)
    ])
    error_message = "Every consumer must reference a declared destination."
  }
}

check "consumer_event_types" {
  assert {
    condition = alltrue([
      for consumer in values(var.consumers) :
      consumer.routing_mode == "all" || try(alltrue([
        for event_type in consumer.event_types :
        contains(var.destinations[consumer.destination].event_types, event_type)
      ]), false)
    ])
    error_message = "Every included event type must be published by the consumer destination."
  }
}

check "entity_names" {
  assert {
    condition = (
      length(local.all_exchange_names) == length(distinct(local.all_exchange_names)) &&
      length(local.all_queue_names) == length(distinct(local.all_queue_names))
    )
    error_message = "Destination, source and dead-letter entity names must be unique within their RabbitMQ namespace."
  }
}

check "workload_user_consistency" {
  assert {
    condition = alltrue([
      for candidates in values(local.workload_user_candidates) : length(candidates) == 1
    ])
    error_message = "A workload must use the same RabbitMQ user for publishing and consuming."
  }
}

check "workload_user_isolation" {
  assert {
    condition     = length(values(local.workload_users)) == length(distinct(values(local.workload_users)))
    error_message = "Each workload must use a distinct RabbitMQ user."
  }
}

resource "rabbitmq_vhost" "this" {
  name = var.virtual_host
}

resource "rabbitmq_exchange" "destination" {
  for_each = var.destinations

  name  = each.value.name
  vhost = rabbitmq_vhost.this.name

  settings {
    type        = "topic"
    durable     = true
    auto_delete = false
  }
}

resource "rabbitmq_exchange" "dead_letter" {
  for_each = local.dead_letter_consumers

  name  = each.value.dead_letter.exchange_name
  vhost = rabbitmq_vhost.this.name

  settings {
    type        = "direct"
    durable     = true
    auto_delete = false
  }
}

resource "rabbitmq_queue" "dead_letter" {
  for_each = local.dead_letter_consumers

  name  = each.value.dead_letter.queue_name
  vhost = rabbitmq_vhost.this.name

  settings {
    durable        = true
    auto_delete    = false
    arguments_json = jsonencode({ "x-queue-type" = "quorum" })
  }
}

resource "rabbitmq_binding" "dead_letter" {
  for_each = local.dead_letter_consumers

  source           = rabbitmq_exchange.dead_letter[each.key].name
  vhost            = rabbitmq_vhost.this.name
  destination      = rabbitmq_queue.dead_letter[each.key].name
  destination_type = "queue"
  routing_key      = each.value.dead_letter.routing_key
}

resource "rabbitmq_policy" "consumer" {
  for_each = var.consumers

  name  = "hexagon-${substr(sha1(each.key), 0, 16)}"
  vhost = rabbitmq_vhost.this.name

  policy {
    pattern  = "^${replace(each.value.name, ".", "\\.")}$"
    priority = 10
    apply_to = "queues"
    definition = merge(
      { "delivery-limit" = tostring(each.value.delivery_limit) },
      each.value.dead_letter.enabled ? {
        "dead-letter-exchange"    = rabbitmq_exchange.dead_letter[each.key].name
        "dead-letter-routing-key" = each.value.dead_letter.routing_key
        "dead-letter-strategy"    = "at-least-once"
        "overflow"                = "reject-publish"
      } : {}
    )
  }
}

resource "rabbitmq_queue" "consumer" {
  for_each = var.consumers

  name  = each.value.name
  vhost = rabbitmq_vhost.this.name

  settings {
    durable        = true
    auto_delete    = false
    arguments_json = jsonencode({ "x-queue-type" = "quorum" })
  }

  depends_on = [rabbitmq_policy.consumer]
}

resource "rabbitmq_binding" "event_route" {
  for_each = local.route_bindings

  source           = rabbitmq_exchange.destination[each.value.destination_id].name
  vhost            = rabbitmq_vhost.this.name
  destination      = rabbitmq_queue.consumer[each.value.consumer_id].name
  destination_type = "queue"
  routing_key      = each.value.routing_key
}

resource "rabbitmq_permissions" "workload" {
  for_each = local.workload_permissions

  user  = each.value.user_name
  vhost = rabbitmq_vhost.this.name

  permissions {
    configure = "^$"
    write     = each.value.write
    read      = each.value.read
  }
}

resource "rabbitmq_topic_permissions" "publisher" {
  for_each = local.publisher_destinations_by_workload

  user  = local.workload_users[each.key]
  vhost = rabbitmq_vhost.this.name

  dynamic "permissions" {
    for_each = each.value

    content {
      exchange = permissions.value.exchange_name
      write    = "^(${join("|", sort(tolist(permissions.value.event_types)))})$"
      read     = "^$"
    }
  }
}
