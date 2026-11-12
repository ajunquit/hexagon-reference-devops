locals {
  keycloak_enabled = var.keycloak != null
  keycloak_role    = "${var.name_prefix}-keycloak"
  keycloak_origin  = "https://${var.name_prefix}-auth.${azurerm_container_app_environment.this.default_domain}"
  auth_authority   = local.keycloak_enabled ? "${local.keycloak_origin}/realms/${var.keycloak.realm}" : var.auth.authority
  keycloak_secrets = local.keycloak_enabled ? {
    database  = var.keycloak.database_password
    bootstrap = var.keycloak.bootstrap_password
  } : {}
  keycloak_bootstrap = local.keycloak_enabled ? { role = local.keycloak_role } : null
}

# Only the write-only administrator argument consumes the value. It never enters plans or state.
ephemeral "azurerm_key_vault_secret" "postgres_administrator" {
  count        = local.keycloak_enabled ? 1 : 0
  key_vault_id = var.keycloak.server_password.vault_resource_id
  name         = split("/", var.keycloak.server_password.secret_uri)[4]
  version      = split("/", var.keycloak.server_password.secret_uri)[5]
}

resource "azurerm_user_assigned_identity" "keycloak" {
  count               = local.keycloak_enabled ? 1 : 0
  name                = "${var.name_prefix}-keycloak"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "keycloak_secrets" {
  for_each             = local.keycloak_secrets
  scope                = "${each.value.vault_resource_id}/secrets/${split("/", each.value.secret_uri)[4]}"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.keycloak[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "keycloak_preparation_secret" {
  count                = local.keycloak_enabled ? 1 : 0
  scope                = "${var.keycloak.database_password.vault_resource_id}/secrets/${split("/", var.keycloak.database_password.secret_uri)[4]}"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.maintenance.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_container_app" "keycloak" {
  count                        = var.keycloak_rollout_enabled ? 1 : 0
  name                         = "${var.name_prefix}-auth"
  resource_group_name          = data.azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.keycloak[0].id]
  }
  dynamic "secret" {
    for_each = local.keycloak_secrets
    content {
      name                = secret.key
      key_vault_secret_id = secret.value.secret_uri
      identity            = azurerm_user_assigned_identity.keycloak[0].id
    }
  }
  ingress {
    external_enabled           = true
    allow_insecure_connections = false
    target_port                = 8080
    transport                  = "http"
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }
  template {
    min_replicas = 1
    max_replicas = 1
    container {
      name   = "keycloak"
      image  = var.keycloak.image
      args   = ["start"]
      cpu    = 0.5
      memory = "1Gi"
      dynamic "env" {
        for_each = {
          KC_DB                       = "postgres"
          KC_DB_URL                   = "jdbc:postgresql://${local.database_host}:5432/${var.database_name}?sslmode=verify-full&sslfactory=org.postgresql.ssl.DefaultJavaSSLFactory"
          KC_DB_SCHEMA                = "keycloak"
          KC_DB_USERNAME              = local.keycloak_role
          KC_DB_POOL_INITIAL_SIZE     = "1"
          KC_DB_POOL_MIN_SIZE         = "1"
          KC_DB_POOL_MAX_SIZE         = "5"
          KC_HOSTNAME                 = local.keycloak_origin
          KC_HOSTNAME_STRICT          = "true"
          KC_PROXY_HEADERS            = "xforwarded"
          KC_HTTP_ENABLED             = "true"
          KC_HEALTH_ENABLED           = "true"
          KC_CACHE                    = "local"
          KC_BOOTSTRAP_ADMIN_USERNAME = var.keycloak.bootstrap_user
        }
        content {
          name  = env.key
          value = env.value
        }
      }
      env {
        name        = "KC_DB_PASSWORD"
        secret_name = "database"
      }
      env {
        name        = "KC_BOOTSTRAP_ADMIN_PASSWORD"
        secret_name = "bootstrap"
      }
      startup_probe {
        transport               = "HTTP"
        port                    = 9000
        path                    = "/health/ready"
        interval_seconds        = 10
        failure_count_threshold = 60
      }
      readiness_probe {
        transport = "HTTP"
        port      = 9000
        path      = "/health/ready"
      }
      liveness_probe {
        transport = "HTTP"
        port      = 9000
        path      = "/health/live"
      }
    }
  }
  tags       = local.tags
  depends_on = [azurerm_role_assignment.keycloak_secrets, azurerm_container_app_job.maintenance]
}
