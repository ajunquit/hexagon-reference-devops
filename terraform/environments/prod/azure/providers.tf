provider "azurerm" {
  resource_provider_registrations = "none"
  features {
    servicebus {
      auto_delete_subscription_default_rule = true
    }
  }
}
