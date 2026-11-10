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
      consumer.routing_mode == "all" || alltrue([
        for event_type in consumer.event_types :
        contains(var.destinations[consumer.destination].event_types, event_type)
      ])
    ])
    error_message = "Every included event type must be published by the consumer destination."
  }
}

resource "azurerm_servicebus_namespace" "this" {
  name                          = var.namespace.name
  location                      = var.location
  resource_group_name           = var.resource_group_name
  sku                           = var.namespace.sku
  capacity                      = var.namespace.capacity
  local_auth_enabled            = false
  minimum_tls_version           = "1.2"
  public_network_access_enabled = var.namespace.public_network_access_enabled
  tags                          = var.tags
}

resource "azurerm_servicebus_topic" "this" {
  for_each = var.destinations

  name                                    = each.value.name
  namespace_id                            = azurerm_servicebus_namespace.this.id
  status                                  = "Active"
  default_message_ttl                     = each.value.default_message_ttl
  requires_duplicate_detection            = each.value.duplicate_detection_enabled
  duplicate_detection_history_time_window = each.value.duplicate_detection_history_time_window
}

resource "azurerm_servicebus_subscription" "this" {
  for_each = var.consumers

  name                                      = each.value.name
  topic_id                                  = azurerm_servicebus_topic.this[each.value.destination].id
  status                                    = "Active"
  max_delivery_count                        = each.value.max_delivery_count
  lock_duration                             = each.value.lock_duration
  default_message_ttl                       = each.value.default_message_ttl
  dead_lettering_on_message_expiration      = each.value.dead_letter_on_message_expiration
  dead_lettering_on_filter_evaluation_error = true
}

resource "azurerm_servicebus_subscription_rule" "all_events" {
  for_each = local.all_event_rules

  name            = "all"
  subscription_id = azurerm_servicebus_subscription.this[each.key].id
  filter_type     = "SqlFilter"
  sql_filter      = "1=1"
}

resource "azurerm_servicebus_subscription_rule" "included_events" {
  for_each = local.included_event_rules

  name            = "event-${substr(sha1(each.value.event_type), 0, 16)}"
  subscription_id = azurerm_servicebus_subscription.this[each.value.consumer_id].id
  filter_type     = "CorrelationFilter"

  correlation_filter {
    label = each.value.event_type
  }
}

resource "azurerm_role_assignment" "senders" {
  for_each = local.sender_assignments

  scope                = azurerm_servicebus_topic.this[each.value.destination_id].id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = each.value.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "receivers" {
  for_each = var.consumers

  scope                = azurerm_servicebus_subscription.this[each.key].id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = each.value.principal_id
  principal_type       = "ServicePrincipal"
}
