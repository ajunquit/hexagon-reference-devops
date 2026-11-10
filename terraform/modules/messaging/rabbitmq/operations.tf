variable "operations" {
  description = "Existing per-consumer operator users; never creates users or persists passwords."
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
}

resource "rabbitmq_permissions" "operations" {
  for_each = var.operations.operator_identities

  user  = each.value
  vhost = rabbitmq_vhost.this.name

  permissions {
    configure = "^$"
    write     = var.consumers[each.key].dead_letter.enabled && var.operations.consumers[each.key].replay_enabled ? "^${replace(var.destinations[var.consumers[each.key].destination].name, ".", "\\.")}$" : "^$"
    read      = "^(${replace(var.consumers[each.key].name, ".", "\\.")}${var.consumers[each.key].dead_letter.enabled ? "|${replace(var.consumers[each.key].dead_letter.queue_name, ".", "\\.")}" : ""})$"
  }

  lifecycle {
    precondition {
      condition     = !contains(values(local.workload_users), each.value)
      error_message = "Operations users must be separate from application workloads."
    }
  }
}

# A failed operator run must never exhaust the quorum queue's default delivery limit.
# A policy updates existing DLQs without redeclaring or replacing their data.
resource "rabbitmq_policy" "quarantine" {
  for_each = local.dead_letter_consumers

  name  = "hexagon-quarantine-${substr(sha1(each.key), 0, 16)}"
  vhost = rabbitmq_vhost.this.name

  policy {
    pattern    = "^${replace(each.value.dead_letter.queue_name, ".", "\\.")}$"
    priority   = 20
    apply_to   = "queues"
    definition = { "delivery-limit" = "-1" }
  }
}

resource "rabbitmq_topic_permissions" "operations" {
  for_each = { for id, user in var.operations.operator_identities : id => user if var.consumers[id].dead_letter.enabled && var.operations.consumers[id].replay_enabled }

  user  = each.value
  vhost = rabbitmq_vhost.this.name

  permissions {
    exchange = var.destinations[var.consumers[each.key].destination].name
    write    = "^(${join("|", sort(tolist(var.consumers[each.key].routing_mode == "all" ? var.destinations[var.consumers[each.key].destination].event_types : var.consumers[each.key].event_types)))})$"
    read     = "^$"
  }
}
