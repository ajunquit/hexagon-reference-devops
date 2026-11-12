variable "keycloak" {
  description = "Optional integrated dev identity. Only an immutable official image is accepted; its secrets are created empty here and filled outside Terraform."
  type        = object({ image = string, realm = string, bootstrap_user = string })
  default     = null
  validation {
    condition = var.keycloak == null ? true : (
      var.environment == "dev" && var.auth.authority == null &&
      can(regex("^quay[.]io/keycloak/keycloak@sha256:[0-9a-f]{64}$", var.keycloak.image)) &&
      can(regex("^[a-z][a-z0-9-]{0,62}$", var.keycloak.realm)) && var.keycloak.realm != "master" &&
      can(regex("^[A-Za-z][A-Za-z0-9._-]{0,62}$", var.keycloak.bootstrap_user))
    )
    error_message = "Integrated Keycloak requires dev, a null external authority, a pinned official image and a non-master realm."
  }
}

variable "keycloak_rollout_enabled" {
  type        = bool
  default     = false
  description = "Enable only after the keycloak-database maintenance task has succeeded."
  validation {
    condition     = !var.keycloak_rollout_enabled || (var.keycloak != null && var.maintenance_jobs_enabled)
    error_message = "Prepare the integrated identity database before enabling Keycloak rollout."
  }
}
