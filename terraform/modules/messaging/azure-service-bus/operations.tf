variable "operations" {
  description = "Optional per-consumer alert policy; application workload permissions remain unchanged."
  type = object({
    notification_targets = list(string)
    operator_identities  = map(string)
    consumers = map(object({
      backlog_threshold          = number
      replay_enabled             = optional(bool, false)
      dead_letter_threshold      = optional(number)
      oldest_message_age_seconds = optional(number)
    }))
  })
  default = { notification_targets = [], operator_identities = {}, consumers = {} }

  validation {
    condition = length(var.operations.consumers) == 0 ? length(var.operations.operator_identities) == 0 : (
      toset(keys(var.operations.consumers)) == toset(keys(var.consumers)) &&
      toset(keys(var.operations.operator_identities)) == toset(keys(var.consumers)) &&
      length(distinct(values(var.operations.operator_identities))) == length(var.operations.operator_identities)
    )
    error_message = "An operations policy must cover every consumer with a distinct operator identity."
  }

  validation {
    condition = alltrue([
      for policy in values(var.operations.consumers) :
      policy.backlog_threshold >= 1 &&
      (policy.dead_letter_threshold == null ? true : policy.dead_letter_threshold >= 1)
    ])
    error_message = "Alert thresholds must be positive."
  }
}

locals {
  operations_topics = toset([for id in keys(var.operations.consumers) : var.consumers[id].destination])
  operations_signals = merge([
    for destination in local.operations_topics : {
      for signal in ["ActiveMessages", "DeadletteredMessages"] : "${destination}/${signal}" => {
        destination = destination
        metric      = signal
        threshold = min([
          for id, policy in var.operations.consumers :
          signal == "ActiveMessages" ? policy.backlog_threshold : policy.dead_letter_threshold
          if var.consumers[id].destination == destination
        ]...)
      }
    }
  ]...)
}

resource "azurerm_monitor_metric_alert" "messaging" {
  for_each = local.operations_signals

  name                = "${var.namespace.name}-${substr(sha1(each.key), 0, 12)}"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_servicebus_namespace.this.id]
  description         = "${each.value.metric} on topic ${var.destinations[each.value.destination].name}; inspect individual subscriptions with the operations runbook."
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.ServiceBus/namespaces"
    metric_name      = each.value.metric
    aggregation      = "Maximum"
    operator         = "GreaterThanOrEqual"
    threshold        = each.value.threshold

    dimension {
      name     = "EntityName"
      operator = "Include"
      values   = [var.destinations[each.value.destination].name]
    }
  }

  dynamic "action" {
    for_each = toset(var.operations.notification_targets)
    content {
      action_group_id = action.value
    }
  }

  lifecycle {
    precondition {
      condition     = length(var.operations.notification_targets) > 0 && toset(keys(var.operations.consumers)) == toset(keys(var.consumers))
      error_message = "Operations require notification targets and an exact consumer policy."
    }
  }
}

resource "azurerm_role_assignment" "operations_receive" {
  for_each = var.operations.operator_identities

  scope                = azurerm_servicebus_subscription.this[each.key].id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = each.value
  principal_type       = "ServicePrincipal"

  lifecycle {
    precondition {
      condition     = !contains([for consumer in values(var.consumers) : consumer.principal_id], each.value) && !contains(flatten([for destination in values(var.destinations) : values(destination.publishers)]), each.value)
      error_message = "Operations identities must be separate from application workloads."
    }
  }
}

resource "azurerm_role_assignment" "operations_send" {
  for_each = { for id, principal in var.operations.operator_identities : id => principal if var.operations.consumers[id].replay_enabled }

  scope                = azurerm_servicebus_topic.this[var.consumers[each.key].destination].id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = each.value
  principal_type       = "ServicePrincipal"
}
