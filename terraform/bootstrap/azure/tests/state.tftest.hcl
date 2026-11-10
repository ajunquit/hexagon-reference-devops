mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = { object_id = "33333333-3333-3333-3333-333333333333" }
  }
}

run "protects_remote_state_with_identity_and_recovery" {
  command = plan

  variables {
    product                = "hexagon-example"
    resource_group_name    = "rg-hexagon-example-tfstate"
    location               = "eastus2"
    storage_account_name   = "sthexagonexample0001"
    environment_groups     = { rg-example-dev = "dev", rg-example-staging = "staging", rg-example-prod = "prod" }
    environment_containers = { dev = "tfstate-dev", staging = "tfstate-staging", prod = "tfstate-prod" }
    tags = {
      managed-by = "terraform"
    }
  }

  assert {
    condition     = length(azurerm_storage_container.environment) == 3 && length(azurerm_resource_group.environment) == 3
    error_message = "Bootstrap must own persistent boundaries and isolated state containers."
  }

  assert {
    condition     = azurerm_storage_account.state.shared_access_key_enabled == false
    error_message = "Terraform state must authenticate through Microsoft Entra ID."
  }

  assert {
    condition     = azurerm_storage_account.state.blob_properties[0].versioning_enabled == true
    error_message = "Terraform state blobs must be versioned."
  }

  assert {
    condition     = azurerm_storage_account.state.blob_properties[0].delete_retention_policy[0].days == 30
    error_message = "Terraform state must have a recovery window."
  }

  assert {
    condition     = azurerm_management_lock.state.lock_level == "CanNotDelete"
    error_message = "Terraform state storage must be protected against deletion."
  }

  assert {
    condition     = output.state_keys.dev != output.state_keys.staging && output.state_keys.staging != output.state_keys.prod
    error_message = "Each environment must use an independent state key."
  }
}
