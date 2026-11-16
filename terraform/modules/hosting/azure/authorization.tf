locals {
  authorization_environment = { for name, value in var.workloads[var.migration_workload].environment : name => value if startswith(name, "Auth__Authorization__") }
  authorization_enabled     = length(local.authorization_environment) > 0
  authorization_secret      = try(var.workloads[var.migration_workload].secret_references["Auth__Authorization__ClientSecret"], null)
  authorization_task = {
    image       = var.workloads[var.migration_workload].image
    args        = ["--migrate-only", "--reconcile-auth-authorization", "--provision-auth-authorization"]
    environment = merge(local.jobs.migrations.environment, local.authorization_environment)
  }
  authorization_jobs = local.authorization_enabled ? merge(
    { authorization = local.authorization_task },
    var.acceptance_fixture == null ? {} : { acceptance-authorization = local.authorization_task }
  ) : {}
}

# Only API and maintenance may read this exact credential; neither receives the bootstrap token.
resource "azurerm_role_assignment" "authorization_secret" {
  for_each = local.authorization_enabled ? {
    api         = azurerm_user_assigned_identity.workload[local.api_id].principal_id
    maintenance = azurerm_user_assigned_identity.maintenance.principal_id
  } : {}
  scope                = "${local.authorization_secret.vault_resource_id}/secrets/${split("/", local.authorization_secret.secret_uri)[4]}"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = each.value
  principal_type       = "ServicePrincipal"
}
