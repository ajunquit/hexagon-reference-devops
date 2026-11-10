locals {
  prefix        = "${var.product}-${var.environment}-${var.instance_id}"
  tags          = { product = var.product, environment = var.environment, instance = var.instance_id, managed-by = "terraform", expires-at = tostring(var.expires_at) }
  storage_scope = "/subscriptions/${var.subscription_id}/resourceGroups/${var.state_resource_group}/providers/Microsoft.Storage/storageAccounts/${var.storage_account_name}"
  delegated_roles = [
    "7f951dda-4ed3-4680-a7ca-43fe172d538d",
    "4633458b-17de-408a-b874-0445c86b69e6",
    "69a216fc-b8fb-44d8-bc22-1f3c2cd27a39",
    "4f6d3b9b-027b-4f4c-9142-0e7da12a66a2",
  ]
  delegation_condition = join(" AND ", [for operation, attribute in { write = "Request", delete = "Resource" } :
    "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/${operation}'})) OR (@${attribute}[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${join(", ", local.delegated_roles)}} AND @${attribute}[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {'ServicePrincipal'}))"
  ])
}

resource "azurerm_resource_group" "workload" {
  for_each = var.roots
  name     = "rg-${local.prefix}-${each.key}"
  location = var.location
  tags     = local.tags
  lifecycle { prevent_destroy = true }
}

resource "azurerm_storage_container" "instance" {
  name                  = "tfstate-${var.instance_id}-${var.environment}"
  storage_account_id    = local.storage_scope
  container_access_type = "private"
  lifecycle { prevent_destroy = true }
}

resource "azurerm_user_assigned_identity" "deployment" {
  name                = "id-${local.prefix}-deploy"
  resource_group_name = var.state_resource_group
  location            = var.location
  tags                = local.tags
  lifecycle { prevent_destroy = true }
}

resource "azurerm_federated_identity_credential" "github" {
  name                      = "github-${var.instance_id}"
  user_assigned_identity_id = azurerm_user_assigned_identity.deployment.id
  issuer                    = "https://token.actions.githubusercontent.com"
  audience                  = ["api://AzureADTokenExchange"]
  subject                   = "${var.oidc_prefix}:environment:${var.environment}-${var.instance_id}"
}

resource "azurerm_role_assignment" "state" {
  scope                = "${local.storage_scope}/blobServices/default/containers/${azurerm_storage_container.instance.name}"
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.deployment.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "deployment" {
  for_each             = var.roots
  scope                = azurerm_resource_group.workload[each.key].id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.deployment.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "delegation" {
  for_each             = var.roots
  scope                = azurerm_resource_group.workload[each.key].id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azurerm_user_assigned_identity.deployment.principal_id
  principal_type       = "ServicePrincipal"
  condition_version    = "2.0"
  condition            = local.delegation_condition
}
