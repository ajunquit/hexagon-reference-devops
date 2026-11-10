mock_provider "azurerm" {}

run "builds_topics_subscriptions_filters_and_least_privilege_roles" {
  command = plan

  variables {
    resource_group_name = "rg-hexagon-example-dev"
    operations = {
      notification_targets = ["/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-example/providers/Microsoft.Insights/actionGroups/example"]
      operator_identities = {
        worker       = "00000000-0000-0000-0000-000000000011"
        sales-worker = "00000000-0000-0000-0000-000000000012"
      }
      consumers = {
        worker       = { backlog_threshold = 1000, dead_letter_threshold = 1 }
        sales-worker = { backlog_threshold = 500, dead_letter_threshold = 1, replay_enabled = true }
      }
    }
    location = "eastus2"
    namespace = {
      name                          = "sb-hexagon-example-dev-0001"
      sku                           = "Standard"
      public_network_access_enabled = true
    }
    destinations = {
      integration-events = {
        name                                    = "integration-events"
        default_message_ttl                     = "P14D"
        duplicate_detection_enabled             = true
        duplicate_detection_history_time_window = "PT10M"
        event_types                             = ["CustomerCreatedIntegrationEvent"]
        publishers = {
          hexagon-example-api          = "00000000-0000-0000-0000-000000000001"
          hexagon-example-worker       = "00000000-0000-0000-0000-000000000002"
          hexagon-example-sales-worker = "00000000-0000-0000-0000-000000000003"
        }
      }
    }
    consumers = {
      worker = {
        name                              = "worker"
        destination                       = "integration-events"
        workload                          = "hexagon-example-worker"
        principal_id                      = "00000000-0000-0000-0000-000000000002"
        routing_mode                      = "all"
        event_types                       = []
        max_delivery_count                = 10
        lock_duration                     = "PT1M"
        default_message_ttl               = "P14D"
        dead_letter_on_message_expiration = true
      }
      sales-worker = {
        name                              = "sales-worker"
        destination                       = "integration-events"
        workload                          = "hexagon-example-sales-worker"
        principal_id                      = "00000000-0000-0000-0000-000000000003"
        routing_mode                      = "include"
        event_types                       = ["CustomerCreatedIntegrationEvent"]
        max_delivery_count                = 10
        lock_duration                     = "PT1M"
        default_message_ttl               = "P14D"
        dead_letter_on_message_expiration = true
      }
    }
  }

  assert {
    condition     = alltrue([for role in concat(values(azurerm_role_assignment.senders), values(azurerm_role_assignment.receivers), values(azurerm_role_assignment.operations_receive), values(azurerm_role_assignment.operations_send)) : role.principal_type == "ServicePrincipal"])
    error_message = "Delegated RBAC requires explicit service principal types for workloads and operators."
  }
  assert {
    condition     = azurerm_servicebus_namespace.this.local_auth_enabled == false
    error_message = "The namespace must only accept identity-based authentication."
  }

  assert {
    condition     = length(azurerm_monitor_metric_alert.messaging) == 2 && azurerm_monitor_metric_alert.messaging["integration-events/ActiveMessages"].criteria[0].threshold == 500
    error_message = "Azure must group native topic metrics and use the strictest consumer threshold."
  }

  assert {
    condition     = length(azurerm_role_assignment.operations_receive) == 2 && length(azurerm_role_assignment.operations_send) == 1 && !contains(keys(azurerm_role_assignment.operations_send), "worker")
    error_message = "Operations identities require explicit scoped roles separate from workloads."
  }

  assert {
    condition     = length(azurerm_servicebus_topic.this) == 1 && length(azurerm_servicebus_subscription.this) == 2
    error_message = "The logical topology was not materialized."
  }

  assert {
    condition     = length(azurerm_servicebus_subscription_rule.all_events) == 1 && length(azurerm_servicebus_subscription_rule.included_events) == 1
    error_message = "Each subscription must receive an explicit all or include rule."
  }

  assert {
    condition     = azurerm_servicebus_subscription_rule.included_events["sales-worker/CustomerCreatedIntegrationEvent"].correlation_filter[0].label == "CustomerCreatedIntegrationEvent"
    error_message = "Include routing must filter on the integration event type carried in Subject."
  }

  assert {
    condition     = length(azurerm_role_assignment.senders) == 3 && length(azurerm_role_assignment.receivers) == 2
    error_message = "Every declared workload must get only its sender or receiver role."
  }

  assert {
    condition     = output.workload_bindings["hexagon-example-sales-worker"]["Messaging__AzureServiceBus__Consumers__sales-worker__Subscription"] == "sales-worker"
    error_message = "Consumer runtime bindings were not generated."
  }

  assert {
    condition     = output.workload_bindings["hexagon-example-api"]["ConnectionStrings__servicebus"] == "sb-hexagon-example-dev-0001.servicebus.windows.net"
    error_message = "The identity-based Service Bus namespace binding is incorrect."
  }
}
