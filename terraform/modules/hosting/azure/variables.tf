variable "product" { type = string }
variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Unknown product environment."
  }
}
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "name_prefix" {
  description = "Globally unique Azure-safe prefix, owned by the product environment."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,18}$", var.name_prefix))
    error_message = "Use a lowercase prefix of 3 to 19 characters."
  }
}
variable "registry_name" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9]{4,49}$", var.registry_name))
    error_message = "Invalid Azure Container Registry name."
  }
}
variable "virtual_network_cidr" { type = string }
variable "application_subnet_cidr" { type = string }
variable "database_subnet_cidr" { type = string }
variable "database_name" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.database_name))
    error_message = "Invalid PostgreSQL database identifier."
  }
}
variable "database_connection_name" { type = string }
variable "database_sku" { type = string }
variable "database_storage_mb" { type = number }
variable "messaging_enabled" {
  type    = bool
  default = true
  validation {
    condition     = var.messaging_enabled || alltrue([for workload in values(var.workloads) : workload.kind == "api"])
    error_message = "Messaging-free hosting supports only API workloads."
  }
}
variable "auth" {
  description = "External Hexagon Auth bindings, or a null authority for integrated Keycloak."
  type        = object({ authority = string, client_id = string, audience = string, api_scope = string })
  validation {
    condition     = var.auth.authority == null ? true : (can(regex("^https://[A-Za-z0-9.-]+(?::443)?/[^?#@]+$", var.auth.authority)) && !endswith(var.auth.authority, "/"))
    error_message = "Hexagon Auth requires a public HTTPS issuer."
  }
}
variable "workloads" {
  type = map(object({
    name        = string, kind = string, image = string,
    http_ports  = list(number), health_port = number,
    environment = map(string), secret_references = map(object({ secret_uri = string, vault_resource_id = string })),
    cpu         = number, memory = string, min_replicas = number, max_replicas = number
  }))
  validation {
    condition = alltrue([for workload in values(var.workloads) :
      contains(["api", "consumer"], workload.kind) &&
      can(regex("^[a-z0-9.-]+(?::[0-9]+)?/[a-z0-9._/-]+@sha256:[0-9a-f]{64}$", workload.image)) &&
      workload.health_port == 8081 && workload.http_ports == (workload.kind == "api" ? tolist([8080, 8081]) : tolist([8081])) &&
      startswith(workload.image, "${var.registry_name}.azurecr.io/") &&
      contains([0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], workload.cpu) && workload.memory == "${workload.cpu * 2}Gi" &&
      workload.min_replicas >= 1 && workload.max_replicas >= workload.min_replicas
    ]) && length([for workload in values(var.workloads) : workload if workload.kind == "api"]) == 1
    error_message = "Exactly one API, immutable image digests, health ports and at least one replica are required."
  }
  validation {
    condition = alltrue([for workload in values(var.workloads) :
      alltrue([for key in keys(workload.environment) : !can(regex("(?i)(password|token|secret)", key))]) &&
      length(setintersection(toset(keys(workload.environment)), toset(keys(workload.secret_references)))) == 0 &&
      alltrue([for secret in values(workload.secret_references) :
        can(regex("^https://[a-z0-9-]+[.]vault[.]azure[.]net/secrets/[A-Za-z0-9-]+(/[a-f0-9]{32})?$", secret.secret_uri)) &&
        can(regex("^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft.KeyVault/vaults/[^/]+$", secret.vault_resource_id)) &&
        startswith(lower(secret.secret_uri), "https://${lower(element(reverse(split("/", secret.vault_resource_id)), 0))}.vault.azure.net/")
      ])
    ])
    error_message = "Use Key Vault references for credentials, without duplicate environment keys, and match each secret to its vault scope."
  }
}
variable "migration_workload" {
  type = string
  validation {
    condition     = try(var.workloads[var.migration_workload].kind == "api", false)
    error_message = "Migrations must use the API artifact."
  }
}
variable "bootstrap_image" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9.-]+/[a-z0-9._/-]+@sha256:[0-9a-f]{64}$", var.bootstrap_image)) && startswith(var.bootstrap_image, "${var.registry_name}.azurecr.io/")
    error_message = "The database bootstrap job requires an immutable image digest."
  }
}
variable "application_rollout_enabled" {
  description = "Enable only after the migration and principal bootstrap jobs succeed."
  type        = bool
  default     = false
  validation {
    condition     = !var.application_rollout_enabled || (var.maintenance_jobs_enabled && (var.keycloak == null || var.keycloak_rollout_enabled))
    error_message = "Create and complete the maintenance jobs before enabling application rollout."
  }
}
variable "maintenance_jobs_enabled" {
  description = "Enable after the initial infrastructure exists and immutable images are available in ACR."
  type        = bool
  default     = false
}
variable "tags" { type = map(string) }

variable "acceptance_fixture" {
  description = "Optional isolated initial tenants for ephemeral acceptance; never an identity credential."
  type        = object({ instanceId = string, subjectId = string, tenant = string, otherTenant = string })
  default     = null
  validation {
    condition = var.acceptance_fixture == null ? true : (
      var.environment != "prod" && can(regex("^run-[1-9][0-9]{0,19}-[1-9][0-9]{0,3}$", var.acceptance_fixture.instanceId)) &&
      can(regex("^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$", var.acceptance_fixture.subjectId)) &&
      var.acceptance_fixture.tenant == "e2e-${var.acceptance_fixture.instanceId}-a" &&
      var.acceptance_fixture.otherTenant == "e2e-${var.acceptance_fixture.instanceId}-b"
    )
    error_message = "Acceptance fixtures require dev/staging, an ephemeral instance, a subject UUID and exactly its two isolated tenants."
  }
}
