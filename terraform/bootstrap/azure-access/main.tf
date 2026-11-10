locals {
  storage_scope = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.Storage/storageAccounts/${var.storage_account_name}"
  groups = merge([for environment, settings in var.environments : {
    for group in settings.resource_groups : group => environment
  }]...)
  # Only application data roles may be delegated; never Contributor, Owner or RBAC Administrator.
  delegated_roles = [
    "7f951dda-4ed3-4680-a7ca-43fe172d538d", # AcrPull
    "4633458b-17de-408a-b874-0445c86b69e6", # Key Vault Secrets User
    "69a216fc-b8fb-44d8-bc22-1f3c2cd27a39", # Azure Service Bus Data Sender
    "4f6d3b9b-027b-4f4c-9142-0e7da12a66a2", # Azure Service Bus Data Receiver
  ]
  delegation_condition = join(" AND ", [for operation, attribute in { write = "Request", delete = "Resource" } :
    "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/${operation}'})) OR (@${attribute}[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${join(", ", local.delegated_roles)}} AND @${attribute}[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {'ServicePrincipal'}))"
  ])
}

resource "azurerm_user_assigned_identity" "deployment" {
  for_each            = var.environments
  name                = each.value.identity_name
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = { product = var.product, environment = each.key, managed-by = "terraform" }
}

resource "azurerm_federated_identity_credential" "github" {
  for_each                  = var.environments
  name                      = "github-${each.key}"
  user_assigned_identity_id = azurerm_user_assigned_identity.deployment[each.key].id
  issuer                    = "https://token.actions.githubusercontent.com"
  audience                  = ["api://AzureADTokenExchange"]
  subject                   = "${var.oidc_prefix}:environment:${each.key}"
}

resource "azurerm_role_assignment" "state" {
  for_each             = var.environments
  scope                = "${local.storage_scope}/blobServices/default/containers/${each.value.state_container}"
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.deployment[each.key].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "deployment" {
  for_each             = local.groups
  scope                = "/subscriptions/${var.subscription_id}/resourceGroups/${each.key}"
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.deployment[each.value].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "delegation" {
  for_each             = local.groups
  scope                = "/subscriptions/${var.subscription_id}/resourceGroups/${each.key}"
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azurerm_user_assigned_identity.deployment[each.value].principal_id
  principal_type       = "ServicePrincipal"
  condition_version    = "2.0"
  condition            = local.delegation_condition
}
