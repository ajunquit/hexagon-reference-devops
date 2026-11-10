mock_provider "rabbitmq" {}

run "builds_quorum_queues_routes_optional_dead_lettering_and_least_privilege" {
  command = plan

  variables {
    virtual_host = "hexagon-example-dev"
    operations = {
      notification_targets = []
      operator_identities = {
        worker       = "hexagon-example-dev-worker-operations"
        sales-worker = "hexagon-example-dev-sales-worker-operations"
      }
      consumers = {
        worker       = { backlog_threshold = 1000 }
        sales-worker = { backlog_threshold = 500, dead_letter_threshold = 1, replay_enabled = true }
      }
    }
    destinations = {
      integration-events = {
        name        = "hexagon-example.dev.integration-events"
        event_types = ["CustomerCreatedIntegrationEvent"]
        publishers = {
          hexagon-example-api          = "hexagon-example-dev-api"
          hexagon-example-worker       = "hexagon-example-dev-worker"
          hexagon-example-sales-worker = "hexagon-example-dev-sales-worker"
        }
      }
    }
    consumers = {
      worker = {
        name           = "hexagon-example.dev.worker"
        destination    = "integration-events"
        workload       = "hexagon-example-worker"
        user_name      = "hexagon-example-dev-worker"
        routing_mode   = "all"
        event_types    = []
        delivery_limit = 5
        dead_letter = {
          enabled = false
        }
      }
      sales-worker = {
        name           = "hexagon-example.dev.sales-worker"
        destination    = "integration-events"
        workload       = "hexagon-example-sales-worker"
        user_name      = "hexagon-example-dev-sales-worker"
        routing_mode   = "include"
        event_types    = ["CustomerCreatedIntegrationEvent"]
        delivery_limit = 5
        dead_letter = {
          enabled       = true
          exchange_name = "hexagon-example.dev.sales-worker.dlx"
          queue_name    = "hexagon-example.dev.sales-worker.dlq"
          routing_key   = "hexagon-example.dev.sales-worker.dead-letter"
        }
      }
    }
  }

  assert {
    condition     = rabbitmq_vhost.this.name == "hexagon-example-dev"
    error_message = "The topology must use a dedicated virtual host."
  }

  assert {
    condition     = rabbitmq_policy.quarantine["sales-worker"].policy[0].definition["delivery-limit"] == "-1"
    error_message = "Operator failures must not exhaust a quarantine queue's delivery limit."
  }

  assert {
    condition     = length(rabbitmq_permissions.operations) == 2 && length(rabbitmq_topic_permissions.operations) == 1 && rabbitmq_permissions.operations["sales-worker"].permissions[0].configure == "^$"
    error_message = "Operator users may only inspect their queues and replay enabled DLQs, without configuring topology."
  }

  assert {
    condition     = length(rabbitmq_exchange.destination) == 1 && rabbitmq_exchange.destination["integration-events"].settings[0].type == "topic"
    error_message = "Each destination must become a durable topic exchange."
  }

  assert {
    condition     = length(rabbitmq_queue.consumer) == 2 && jsondecode(rabbitmq_queue.consumer["worker"].settings[0].arguments_json)["x-queue-type"] == "quorum"
    error_message = "Every consumer must get a quorum queue."
  }

  assert {
    condition     = length(rabbitmq_exchange.dead_letter) == 1 && length(rabbitmq_queue.dead_letter) == 1 && contains(keys(rabbitmq_queue.dead_letter), "sales-worker")
    error_message = "Only consumers that opt in must get a dedicated DLX and DLQ."
  }

  assert {
    condition     = length(rabbitmq_binding.event_route) == 2 && rabbitmq_binding.event_route["worker/#"].routing_key == "#"
    error_message = "All routing must use the RabbitMQ wildcard binding."
  }

  assert {
    condition     = rabbitmq_binding.event_route["sales-worker/CustomerCreatedIntegrationEvent"].routing_key == "CustomerCreatedIntegrationEvent"
    error_message = "Include routing must bind each declared integration event type."
  }

  assert {
    condition     = !contains(keys(rabbitmq_policy.consumer["worker"].policy[0].definition), "dead-letter-exchange")
    error_message = "A queue that disables dead-lettering must not receive DLX settings."
  }

  assert {
    condition = (
      rabbitmq_policy.consumer["sales-worker"].policy[0].definition["delivery-limit"] == "5" &&
      rabbitmq_policy.consumer["sales-worker"].policy[0].definition["dead-letter-strategy"] == "at-least-once" &&
      rabbitmq_policy.consumer["sales-worker"].policy[0].definition["overflow"] == "reject-publish"
    )
    error_message = "DLQ routing must use a bounded delivery limit and at-least-once dead-lettering."
  }

  assert {
    condition     = length(rabbitmq_permissions.workload) == 3 && rabbitmq_permissions.workload["hexagon-example-sales-worker"].permissions[0].configure == "^$"
    error_message = "Every workload must be unable to configure RabbitMQ topology."
  }

  assert {
    condition = (
      strcontains(rabbitmq_permissions.workload["hexagon-example-sales-worker"].permissions[0].read, "sales-worker") &&
      !strcontains(rabbitmq_permissions.workload["hexagon-example-sales-worker"].permissions[0].read, "dlq")
    )
    error_message = "Consumers must read only source queues, never DLQs."
  }

  assert {
    condition     = length(rabbitmq_topic_permissions.publisher) == 3 && one(rabbitmq_topic_permissions.publisher["hexagon-example-api"].permissions).write == "^(CustomerCreatedIntegrationEvent)$"
    error_message = "Publisher topic permissions must restrict routing keys to declared event types."
  }

  assert {
    condition     = output.workload_bindings["hexagon-example-sales-worker"]["Messaging__RabbitMq__Consumers__sales-worker__Queue"] == "hexagon-example.dev.sales-worker"
    error_message = "The non-secret consumer queue binding was not generated."
  }

  assert {
    condition     = !contains(keys(output.workload_bindings["hexagon-example-api"]), "Messaging__RabbitMq__Destinations__integration-events__ConnectionString")
    error_message = "Connection strings must never be emitted as non-secret bindings."
  }

  assert {
    condition     = contains(output.workload_connection_requirements["hexagon-example-api"].setting_keys, "Messaging__RabbitMq__Destinations__integration-events__ConnectionString")
    error_message = "The deployment secret manager must receive every required connection setting key."
  }
}
