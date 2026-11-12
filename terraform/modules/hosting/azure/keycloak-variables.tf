variable "keycloak" {
  description = "Optional integrated dev identity. Only immutable image and versioned Key Vault references are accepted."
  type = object({
    image                    = string, realm = string, bootstrap_user = string,
    server_password_revision = number,
    server_password          = object({ secret_uri = string, vault_resource_id = string }),
    database_password        = object({ secret_uri = string, vault_resource_id = string }),
    bootstrap_password       = object({ secret_uri = string, vault_resource_id = string })
  })
  default = null
  validation {
    condition = var.keycloak == null ? true : (
      var.environment == "dev" && var.auth.authority == null &&
      can(regex("^quay[.]io/keycloak/keycloak@sha256:[0-9a-f]{64}$", var.keycloak.image)) &&
      can(regex("^[a-z][a-z0-9-]{0,62}$", var.keycloak.realm)) && var.keycloak.realm != "master" &&
      can(regex("^[A-Za-z][A-Za-z0-9._-]{0,62}$", var.keycloak.bootstrap_user)) &&
      var.keycloak.server_password_revision >= 1 && floor(var.keycloak.server_password_revision) == var.keycloak.server_password_revision &&
      alltrue([for secret in [var.keycloak.server_password, var.keycloak.database_password, var.keycloak.bootstrap_password] :
        can(regex("^https://[a-z0-9-]+[.]vault[.]azure[.]net/secrets/[A-Za-z0-9-]+/[a-f0-9]{32}$", secret.secret_uri)) &&
        startswith(lower(secret.vault_resource_id), lower("/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.KeyVault/vaults/")) &&
        can(regex("^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft.KeyVault/vaults/[a-z0-9-]+$", secret.vault_resource_id)) &&
        startswith(lower(secret.secret_uri), "https://${lower(element(reverse(split("/", secret.vault_resource_id)), 0))}.vault.azure.net/")
      ]) && length(distinct([for secret in [var.keycloak.server_password, var.keycloak.database_password, var.keycloak.bootstrap_password] : lower(join("/", slice(split("/", secret.secret_uri), 0, 5)))])) == 3
    )
    error_message = "Integrated Keycloak requires dev, a null external authority, a pinned official image, a non-master realm, and three distinct versioned secrets in the hosting scope."
  }
}

variable "keycloak_rollout_enabled" {
  type        = bool
  default     = false
  description = "Enable only after the keycloak-database maintenance execution has succeeded."
  validation {
    condition     = !var.keycloak_rollout_enabled || (var.keycloak != null && var.maintenance_jobs_enabled)
    error_message = "Prepare the integrated identity database before enabling Keycloak rollout."
  }
}
