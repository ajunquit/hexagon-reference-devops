output "backend_configuration" {
  description = "Non-secret azurerm backend settings. Authentication is supplied externally."
  value = {
    resource_group_name  = azurerm_resource_group.state.name
    storage_account_name = azurerm_storage_account.state.name
    container_name       = azurerm_storage_container.state.name
    use_azuread_auth     = true
  }
}

output "state_keys" {
  description = "Independent state keys for bootstrap and each product environment."
  value = {
    bootstrap = "${var.product}/bootstrap/state.tfstate"
    access    = "${var.product}/bootstrap/access.tfstate"
    dev       = "${var.product}/dev/terraform.tfstate"
    staging   = "${var.product}/staging/terraform.tfstate"
    prod      = "${var.product}/prod/terraform.tfstate"
  }
}

output "environment_backend_configuration" {
  value = { for environment, container in azurerm_storage_container.environment : environment => {
    resource_group_name  = azurerm_resource_group.state.name
    storage_account_name = azurerm_storage_account.state.name
    container_name       = container.name
    use_azuread_auth     = true
  } }
}
