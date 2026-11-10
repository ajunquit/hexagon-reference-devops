mock_provider "azurerm" {}

variables {
  subscription_id      = "22222222-2222-2222-2222-222222222222"
  tenant_id            = "11111111-1111-1111-1111-111111111111"
  product              = "hexagon-template"
  environment          = "dev"
  instance_id          = "run-12345-1"
  location             = "eastus2"
  state_resource_group = "rg-hexagon-template-state"
  storage_account_name = "sthexagontemplatestate"
  oidc_prefix          = "repo:example-owner@123/hexagon-template-devops@456"
  expires_at           = 2000000000
  roots                = ["hosting", "messaging"]
}

run "isolates_instance_and_preserves_foundation" {
  command = plan
  assert {
    condition     = azurerm_storage_container.instance.name == "tfstate-run-12345-1-dev" && azurerm_storage_container.instance.container_access_type == "private"
    error_message = "The ephemeral identity cannot share the persistent state container."
  }
  assert {
    condition     = azurerm_federated_identity_credential.github.subject == "${var.oidc_prefix}:environment:dev-run-12345-1" && length(azurerm_federated_identity_credential.github.audience) == 1
    error_message = "Federation must identify the exact reserved instance."
  }
  assert {
    condition     = alltrue([for group in azurerm_resource_group.workload : startswith(group.name, "rg-hexagon-template-dev-run-12345-1-") && group.tags.instance == "run-12345-1"])
    error_message = "Groups must belong to the exact instance."
  }
  assert {
    condition     = alltrue([for assignment in azurerm_role_assignment.delegation : assignment.condition_version == "2.0" && !strcontains(assignment.condition, "8e3af657-a8ff-443c-a75c-2fe8c4bcb635")])
    error_message = "Administrative roles cannot be delegated."
  }
}
run "rejects_production" {
  command = plan
  variables { environment = "prod" }
  expect_failures = [var.environment]
}
run "rejects_persistent_instance" {
  command = plan
  variables { instance_id = "persistent" }
  expect_failures = [var.instance_id]
}
