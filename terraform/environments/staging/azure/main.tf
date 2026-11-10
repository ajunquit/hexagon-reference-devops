locals {
  common_tags = merge(var.tags, {
    environment = var.environment
    managed-by  = "terraform"
    product     = var.product
  })
}

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

module "azure_service_bus" {
  operations = var.operations
  source     = "../../../modules/messaging/azure-service-bus"

  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  namespace           = var.namespace
  destinations        = var.destinations
  consumers           = var.consumers
  tags                = local.common_tags
}
