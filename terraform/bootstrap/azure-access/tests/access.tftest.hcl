mock_provider "azurerm" {}

variables {
  subscription_id      = "22222222-2222-2222-2222-222222222222"
  tenant_id            = "11111111-1111-1111-1111-111111111111"
  product              = "hexagon-template"
  location             = "eastus2"
  resource_group_name  = "rg-hexagon-template-state"
  storage_account_name = "sthexagontemplatestate"
  oidc_prefix          = "repo:example-owner@123/hexagon-template-devops@456"
  environments = {
    dev     = { identity_name = "id-dev", resource_groups = ["rg-hexagon-template-dev"], state_container = "tfstate-dev" }
    staging = { identity_name = "id-staging", resource_groups = ["rg-hexagon-template-staging"], state_container = "tfstate-staging" }
    prod    = { identity_name = "id-prod", resource_groups = ["rg-hexagon-template-prod"], state_container = "tfstate-prod" }
  }
}

run "isolates_federation_and_state" {
  command = plan
  assert {
    condition = alltrue([for environment, credential in azurerm_federated_identity_credential.github :
      credential.subject == "${var.oidc_prefix}:environment:${environment}" &&
      credential.issuer == "https://token.actions.githubusercontent.com" &&
      length(credential.audience) == 1 && credential.audience[0] == "api://AzureADTokenExchange"
    ])
    error_message = "Issuer, audience and environment subject must match exactly."
  }
  assert {
    condition = alltrue([for environment, assignment in azurerm_role_assignment.state :
      endswith(assignment.scope, "/containers/tfstate-${environment}") && assignment.role_definition_name == "Storage Blob Data Contributor"
    ])
    error_message = "State access must be limited to the environment container."
  }
  assert {
    condition = alltrue([for name, assignment in azurerm_role_assignment.deployment :
      endswith(assignment.scope, "/resourceGroups/${name}") && assignment.role_definition_name == "Contributor"
    ])
    error_message = "Deployment permissions cannot be subscription-wide."
  }
  assert {
    condition = alltrue([for assignment in azurerm_role_assignment.delegation :
      assignment.condition_version == "2.0" &&
      strcontains(assignment.condition, "@Request[") && strcontains(assignment.condition, "@Resource[") &&
      strcontains(assignment.condition, "ServicePrincipal") &&
      !strcontains(assignment.condition, "b24988ac-6180-42a0-ab88-20f7382dd24c") &&
      !strcontains(assignment.condition, "f58310d9-a9f6-439a-9e8d-f62e7b41a168")
    ])
    error_message = "Delegation must constrain both writes/deletes and exclude administrative roles."
  }
}

run "rejects_shared_identity" {
  command = plan
  variables {
    environments = {
      dev     = { identity_name = "shared", resource_groups = ["rg-dev"], state_container = "tfstate-dev" }
      staging = { identity_name = "shared", resource_groups = ["rg-staging"], state_container = "tfstate-staging" }
      prod    = { identity_name = "id-prod", resource_groups = ["rg-prod"], state_container = "tfstate-prod" }
    }
  }
  expect_failures = [var.environments]
}
