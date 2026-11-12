data "azurerm_client_config" "current" {}

locals {
  tags           = merge(var.tags, { product = var.product, environment = var.environment, managed-by = "terraform" })
  protected_keys = ["ASPNETCORE_ENVIRONMENT", "HTTP_PORTS", "AZURE_CLIENT_ID", "Auth__Authority", "Auth__Audience", "Auth__ApiScope", "AllowedOrigins", "ConnectionStrings__${var.database_connection_name}"]
  api_id         = one([for id, workload in var.workloads : id if workload.kind == "api"])
  database_host  = azurerm_postgresql_flexible_server.this.fqdn
  vault_access = merge([for id, workload in var.workloads : {
    for scope in distinct([for secret in values(workload.secret_references) : secret.vault_resource_id]) : "${id}/${sha1(scope)}" => { workload = id, scope = scope }
  }]...)
  bootstrap = merge({
    host          = local.database_host, database = var.database_name,
    administrator = azurerm_user_assigned_identity.maintenance.name,
    clientId      = azurerm_user_assigned_identity.maintenance.client_id,
    workloads     = { for id, identity in azurerm_user_assigned_identity.workload : identity.name => { objectId = identity.principal_id, readDirectory = var.workloads[id].kind == "api" } }
  }, var.messaging_enabled ? {} : { messagingEnabled = false })
  jobs = {
    migrations = {
      image = var.workloads[var.migration_workload].image
      args  = ["--migrate-only"]
      environment = {
        ASPNETCORE_ENVIRONMENT                               = "Production"
        AZURE_CLIENT_ID                                      = azurerm_user_assigned_identity.maintenance.client_id
        "ConnectionStrings__${var.database_connection_name}" = "Host=${local.database_host};Database=${var.database_name};Username=${azurerm_user_assigned_identity.maintenance.name};SSL Mode=VerifyFull"
        Auth__Authority                                      = local.auth_authority
        Auth__Audience                                       = var.auth.audience
        Auth__ApiScope                                       = var.auth.api_scope
      }
    }
    database-access = {
      image       = var.bootstrap_image
      args        = []
      environment = { HEXAGON_DATABASE_BOOTSTRAP = jsonencode(local.bootstrap) }
    }
  }
  identity_jobs = local.keycloak_enabled ? {
    keycloak-database = {
      image = var.bootstrap_image
      args  = ["--prepare-keycloak"]
      environment = {
        HEXAGON_DATABASE_BOOTSTRAP = jsonencode(merge(local.bootstrap, { purpose = "keycloak" }))
        HEXAGON_KEYCLOAK_DATABASE  = jsonencode(local.keycloak_bootstrap)
      }
    }
  } : {}
  acceptance_jobs = var.acceptance_fixture == null ? {} : {
    acceptance-seed = {
      image       = var.workloads[var.migration_workload].image
      args        = ["--seed-acceptance-only"]
      environment = merge(local.jobs.migrations.environment, { HEXAGON_ACCEPTANCE_SEED = jsonencode(var.acceptance_fixture) })
    }
  }
}

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}
resource "azurerm_virtual_network" "this" {
  name                = "${var.name_prefix}-vnet"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.this.name
  address_space       = [var.virtual_network_cidr]
  tags                = local.tags
}
resource "azurerm_subnet" "applications" {
  name                 = "applications"
  resource_group_name  = data.azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.application_subnet_cidr]
  delegation {
    name = "container-apps"
    service_delegation { name = "Microsoft.App/environments" }
  }
}
resource "azurerm_subnet" "database" {
  name                 = "database"
  resource_group_name  = data.azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.database_subnet_cidr]
  delegation {
    name = "postgresql"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}
resource "azurerm_private_dns_zone" "database" {
  name                = "${var.name_prefix}.postgres.database.azure.com"
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = local.tags
}
resource "azurerm_private_dns_zone_virtual_network_link" "database" {
  name                = "database"
  private_dns_zone_id = azurerm_private_dns_zone.database.id
  virtual_network_id  = azurerm_virtual_network.this.id
}
resource "azurerm_user_assigned_identity" "workload" {
  for_each            = var.workloads
  name                = "${var.name_prefix}-${substr(sha1(each.key), 0, 10)}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = local.tags
}
resource "azurerm_user_assigned_identity" "maintenance" {
  name                = "${var.name_prefix}-maintenance"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = local.tags
}
resource "azurerm_postgresql_flexible_server" "this" {
  lifecycle {
    precondition {
      condition     = var.auth.authority != null || local.keycloak_enabled
      error_message = "Choose an external HTTPS issuer or integrated Keycloak."
    }
  }
  name                              = "${var.name_prefix}-postgres"
  resource_group_name               = data.azurerm_resource_group.this.name
  location                          = var.location
  version                           = "17"
  sku_name                          = var.database_sku
  storage_mb                        = var.database_storage_mb
  backup_retention_days             = 14
  geo_redundant_backup_enabled      = var.environment == "prod"
  delegated_subnet_id               = azurerm_subnet.database.id
  private_dns_zone_id               = azurerm_private_dns_zone.database.id
  public_network_access_enabled     = false
  administrator_login               = local.keycloak_enabled ? replace("${var.name_prefix}_bootstrap", "-", "_") : null
  administrator_password_wo         = local.keycloak_enabled ? ephemeral.azurerm_key_vault_secret.postgres_administrator[0].value : null
  administrator_password_wo_version = local.keycloak_enabled ? var.keycloak.server_password_revision : null
  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = local.keycloak_enabled
    tenant_id                     = data.azurerm_client_config.current.tenant_id
  }
  tags       = local.tags
  depends_on = [azurerm_private_dns_zone_virtual_network_link.database]
}
resource "azurerm_postgresql_flexible_server_active_directory_administrator" "maintenance" {
  server_name         = azurerm_postgresql_flexible_server.this.name
  resource_group_name = data.azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = azurerm_user_assigned_identity.maintenance.principal_id
  principal_name      = azurerm_user_assigned_identity.maintenance.name
  principal_type      = "ServicePrincipal"
}
resource "azurerm_postgresql_flexible_server_database" "this" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}
resource "azurerm_container_registry" "this" {
  name                = var.registry_name
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = local.tags
}
resource "azurerm_role_assignment" "image_pull" {
  for_each             = merge({ for id, identity in azurerm_user_assigned_identity.workload : id => identity.principal_id }, { maintenance = azurerm_user_assigned_identity.maintenance.principal_id })
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = each.value
  principal_type       = "ServicePrincipal"
}
resource "azurerm_log_analytics_workspace" "this" {
  name                = "${var.name_prefix}-logs"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}
resource "azurerm_role_assignment" "secret_read" {
  for_each             = local.vault_access
  scope                = each.value.scope
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.workload[each.value.workload].principal_id
  principal_type       = "ServicePrincipal"
}
resource "azurerm_container_app_environment" "this" {
  name                       = "${var.name_prefix}-apps"
  resource_group_name        = data.azurerm_resource_group.this.name
  location                   = var.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  infrastructure_subnet_id   = azurerm_subnet.applications.id
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
  tags = local.tags
}
resource "azurerm_static_web_app" "this" {
  name                = "${var.name_prefix}-web"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  sku_tier            = "Standard"
  sku_size            = "Standard"
  tags                = local.tags
}
resource "azurerm_container_app_job" "maintenance" {
  for_each                     = var.maintenance_jobs_enabled ? merge(local.jobs, local.acceptance_jobs, local.identity_jobs) : {}
  name                         = "${var.name_prefix}-${lookup({ database-access = "db-access", acceptance-seed = "e2e-seed", keycloak-database = "kc-database" }, each.key, each.key)}"
  resource_group_name          = data.azurerm_resource_group.this.name
  location                     = var.location
  container_app_environment_id = azurerm_container_app_environment.this.id
  replica_timeout_in_seconds   = 1800
  replica_retry_limit          = 0
  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.maintenance.id]
  }
  registry {
    server   = azurerm_container_registry.this.login_server
    identity = azurerm_user_assigned_identity.maintenance.id
  }
  dynamic "secret" {
    for_each = each.key == "keycloak-database" ? { database = var.keycloak.database_password } : {}
    content {
      name                = "keycloak-database-password"
      key_vault_secret_id = secret.value.secret_uri
      identity            = azurerm_user_assigned_identity.maintenance.id
    }
  }
  template {
    container {
      name   = "maintenance"
      image  = each.value.image
      args   = each.value.args
      cpu    = 0.5
      memory = "1Gi"
      dynamic "env" {
        for_each = each.key == "keycloak-database" ? [1] : []
        content {
          name        = "HEXAGON_KEYCLOAK_DATABASE_PASSWORD"
          secret_name = "keycloak-database-password"
        }
      }
      dynamic "env" {
        for_each = each.value.environment
        content {
          name  = env.key
          value = env.value
        }
      }
    }
  }
  tags       = local.tags
  depends_on = [azurerm_role_assignment.image_pull, azurerm_postgresql_flexible_server_active_directory_administrator.maintenance, azurerm_postgresql_flexible_server_database.this, azurerm_role_assignment.keycloak_preparation_secret]
}
resource "azurerm_container_app" "workload" {
  for_each                     = var.application_rollout_enabled ? var.workloads : {}
  name                         = each.value.name
  resource_group_name          = data.azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.workload[each.key].id]
  }
  registry {
    server   = azurerm_container_registry.this.login_server
    identity = azurerm_user_assigned_identity.workload[each.key].id
  }
  dynamic "secret" {
    for_each = each.value.secret_references
    content {
      name                = "secret-${substr(sha1(secret.key), 0, 12)}"
      key_vault_secret_id = secret.value.secret_uri
      identity            = azurerm_user_assigned_identity.workload[each.key].id
    }
  }
  dynamic "ingress" {
    for_each = each.value.kind == "api" ? [1] : []
    content {
      external_enabled           = true
      allow_insecure_connections = false
      target_port                = 8080
      transport                  = "http"
      traffic_weight {
        latest_revision = true
        percentage      = 100
      }
    }
  }
  template {
    min_replicas = each.value.min_replicas
    max_replicas = each.value.max_replicas
    container {
      name   = "application"
      image  = each.value.image
      cpu    = each.value.cpu
      memory = each.value.memory
      dynamic "env" {
        for_each = merge(each.value.environment, {
          ASPNETCORE_ENVIRONMENT                               = "Production"
          HTTP_PORTS                                           = join(";", each.value.http_ports)
          AZURE_CLIENT_ID                                      = azurerm_user_assigned_identity.workload[each.key].client_id
          "ConnectionStrings__${var.database_connection_name}" = "Host=${local.database_host};Database=${var.database_name};Username=${azurerm_user_assigned_identity.workload[each.key].name};SSL Mode=VerifyFull"
          }, each.value.kind == "api" ? {
          Auth__Authority = local.auth_authority, Auth__Audience = var.auth.audience, Auth__ApiScope = var.auth.api_scope
          AllowedOrigins  = "https://${azurerm_static_web_app.this.default_host_name}"
        } : {})
        content {
          name  = env.key
          value = env.value
        }
      }
      liveness_probe {
        transport = "HTTP"
        port      = each.value.health_port
        path      = "/health/alive"
      }
      dynamic "env" {
        for_each = each.value.secret_references
        content {
          name        = env.key
          secret_name = "secret-${substr(sha1(env.key), 0, 12)}"
        }
      }
      readiness_probe {
        transport = "HTTP"
        port      = each.value.health_port
        path      = "/health/ready"
      }
      startup_probe {
        transport               = "HTTP"
        port                    = each.value.health_port
        path                    = "/health/ready"
        failure_count_threshold = 60
      }
    }
  }
  lifecycle {
    precondition {
      condition     = length(setintersection(setunion(toset(keys(each.value.environment)), toset(keys(each.value.secret_references))), toset(local.protected_keys))) == 0 && length(setintersection(toset(keys(each.value.environment)), toset(keys(each.value.secret_references)))) == 0
      error_message = "Workload bindings cannot override protected hosting or identity settings."
    }
  }
  tags       = local.tags
  depends_on = [azurerm_role_assignment.image_pull, azurerm_role_assignment.secret_read]
}
