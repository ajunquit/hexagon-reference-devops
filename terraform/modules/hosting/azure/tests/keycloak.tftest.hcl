mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = { tenant_id = "00000000-0000-0000-0000-000000000001", subscription_id = "00000000-0000-0000-0000-000000000001" }
  }
}

variables {
  product                  = "hexagon-example"
  environment              = "dev"
  location                 = "eastus2"
  resource_group_name      = "rg-example-dev-hosting"
  name_prefix              = "example-dev-0001"
  registry_name            = "exampledev0001"
  virtual_network_cidr     = "10.42.0.0/16"
  application_subnet_cidr  = "10.42.0.0/23"
  database_subnet_cidr     = "10.42.2.0/24"
  database_name            = "hexagon_example"
  database_connection_name = "HexagonExampleDb"
  database_sku             = "B_Standard_B1ms"
  database_storage_mb      = 32768
  auth = {
    authority = null
    client_id = "example-web"
    audience  = "example-api"
    api_scope = "example_api.all"
  }
  workloads = {
    api = {
      name = "example-dev-api", kind = "api", image = "exampledev0001.azurecr.io/example-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      http_ports = [8080, 8081], health_port = 8081, environment = {}, secret_references = {
        ExternalApi__ApiKey = { secret_uri = "https://examplevault.vault.azure.net/secrets/external-api", vault_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-example-dev-hosting/providers/Microsoft.KeyVault/vaults/examplevault" }
      }
      cpu = 0.5, memory = "1Gi", min_replicas = 1, max_replicas = 2
    }
    worker = {
      name       = "example-dev-worker", kind = "consumer", image = "exampledev0001.azurecr.io/example-worker@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      http_ports = [8081], health_port = 8081, environment = {}, secret_references = {}
      cpu        = 0.5, memory = "1Gi", min_replicas = 1, max_replicas = 2
    }
  }
  migration_workload = "api"
  bootstrap_image    = "exampledev0001.azurecr.io/database-bootstrap@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  tags               = {}
  keycloak = {
    image                    = "quay.io/keycloak/keycloak@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    realm                    = "hexagon"
    bootstrap_user           = "bootstrap"
    server_password_revision = 1
    server_password          = { secret_uri = "https://examplevault.vault.azure.net/secrets/pg-admin/11111111111111111111111111111111", vault_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-example-dev-hosting/providers/Microsoft.KeyVault/vaults/examplevault" }
    database_password        = { secret_uri = "https://examplevault.vault.azure.net/secrets/kc-database/22222222222222222222222222222222", vault_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-example-dev-hosting/providers/Microsoft.KeyVault/vaults/examplevault" }
    bootstrap_password       = { secret_uri = "https://examplevault.vault.azure.net/secrets/kc-bootstrap/33333333333333333333333333333333", vault_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-example-dev-hosting/providers/Microsoft.KeyVault/vaults/examplevault" }
  }

}


run "integrated_genesis_keeps_identity_and_backend_disabled" {
  command = plan
  assert {
    condition     = length(azurerm_container_app.keycloak) == 0 && length(azurerm_container_app.workload) == 0 && length(azurerm_container_app_job.maintenance) == 0
    error_message = "An empty registry and unprepared identity must not start containers."
  }
  assert {
    condition     = azurerm_postgresql_flexible_server.this.authentication[0].active_directory_auth_enabled && azurerm_postgresql_flexible_server.this.authentication[0].password_auth_enabled && !azurerm_postgresql_flexible_server.this.public_network_access_enabled
    error_message = "Integrated identity preserves Entra for applications and permits only the separate private password connection."
  }
}
run "identity_preparation_has_only_a_versioned_database_secret" {
  command = plan
  variables { maintenance_jobs_enabled = true }
  assert {
    condition     = length(azurerm_container_app_job.maintenance) == 3 && azurerm_container_app_job.maintenance["keycloak-database"].template[0].container[0].args == tolist(["--prepare-keycloak"])
    error_message = "Identity database preparation must be an explicit controlled job."
  }
  assert {
    condition     = length(azurerm_container_app_job.maintenance["keycloak-database"].secret) == 1 && one(azurerm_container_app_job.maintenance["keycloak-database"].secret).key_vault_secret_id == var.keycloak.database_password.secret_uri
    error_message = "The SQL job must not receive the server or Keycloak administrator passwords."
  }
}
run "identity_rollout_precedes_backend_and_uses_the_product_database" {
  command = plan
  variables {
    maintenance_jobs_enabled = true
    keycloak_rollout_enabled = true
  }
  assert {
    condition     = length(azurerm_container_app.keycloak) == 1 && length(azurerm_container_app.workload) == 0 && azurerm_postgresql_flexible_server_database.this.name == var.database_name
    error_message = "Identity must share the existing database and start before the backend."
  }
  assert {
    condition     = azurerm_container_app.keycloak[0].ingress[0].target_port == 8080 && !azurerm_container_app.keycloak[0].ingress[0].allow_insecure_connections && azurerm_container_app.keycloak[0].template[0].container[0].readiness_probe[0].port == 9000
    error_message = "Only the HTTPS identity endpoint may be public; management stays internal."
  }
}
run "reject_backend_before_identity" {
  command = plan
  variables {
    maintenance_jobs_enabled    = true
    application_rollout_enabled = true
  }
  expect_failures = [var.application_rollout_enabled]
}
run "reject_identity_without_maintenance" {
  command = plan
  variables {
    keycloak_rollout_enabled = true
  }
  expect_failures = [var.keycloak_rollout_enabled]
}
run "reject_integrated_production" {
  command = plan
  variables { environment = "prod" }
  expect_failures = [var.keycloak]
}
run "reject_two_issuers" {
  command = plan
  variables { auth = { authority = "https://auth.example.test/realms/hexagon", client_id = "example-web", audience = "example-api", api_scope = "example_api.all" } }
  expect_failures = [var.keycloak]
}
run "reject_shared_secret_name_even_with_different_versions" {
  command = plan
  variables {
    keycloak = {
      image                    = "quay.io/keycloak/keycloak@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
      realm                    = "hexagon"
      bootstrap_user           = "bootstrap"
      server_password_revision = 1
      server_password          = { secret_uri = "https://examplevault.vault.azure.net/secrets/shared/11111111111111111111111111111111", vault_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-example-dev-hosting/providers/Microsoft.KeyVault/vaults/examplevault" }
      database_password        = { secret_uri = "https://examplevault.vault.azure.net/secrets/shared/22222222222222222222222222222222", vault_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-example-dev-hosting/providers/Microsoft.KeyVault/vaults/examplevault" }
      bootstrap_password       = { secret_uri = "https://examplevault.vault.azure.net/secrets/kc-bootstrap/33333333333333333333333333333333", vault_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-example-dev-hosting/providers/Microsoft.KeyVault/vaults/examplevault" }
    }
  }
  expect_failures = [var.keycloak]
}

run "authorization_preparation_is_separate_and_uses_only_its_credential" {
  command = plan
  variables {
    maintenance_jobs_enabled = true
    workloads = {
      api = {
        name              = "example-dev-api", kind = "api", image = "exampledev0001.azurecr.io/example-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        http_ports        = [8080, 8081], health_port = 8081
        cpu               = 0.5, memory = "1Gi", min_replicas = 1, max_replicas = 1
        environment       = { Auth__Authorization__Product = "hexagon-example", Auth__Authorization__ResourceServerId = "00000000-0000-4000-8000-000000000001", Auth__Authorization__ClientId = "hexagon-example-dev-authorization" }
        secret_references = { Auth__Authorization__ClientSecret = { secret_uri = "https://examplevault.vault.azure.net/secrets/authorization-client/44444444444444444444444444444444", vault_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-example-dev-hosting/providers/Microsoft.KeyVault/vaults/examplevault" } }
      }
    }
  }
  assert {
    condition     = azurerm_container_app_job.maintenance["authorization"].template[0].container[0].args == tolist(["--migrate-only", "--reconcile-auth-authorization", "--provision-auth-authorization"])
    error_message = "Authorization must finish in an explicit maintenance task before the rollout."
  }
  assert {
    condition     = local.authorization_jobs["authorization"].environment.Auth__Authorization__Product == var.product && !contains(keys(local.authorization_jobs), "acceptance-authorization")
    error_message = "Authorization binds the product; acceptance authorization exists only with its isolated fixture."
  }
  assert {
    condition     = length(azurerm_role_assignment.authorization_secret) == 2 && one(azurerm_container_app_job.maintenance["authorization"].secret).key_vault_secret_id == var.workloads.api.secret_references.Auth__Authorization__ClientSecret.secret_uri
    error_message = "Only API and maintenance may read the exact client credential, never the bootstrap password."
  }
}

run "reject_authorization_foreign_product" {
  command = plan
  variables {
    workloads = {
      api = {
        name              = "example-dev-api", kind = "api", image = "exampledev0001.azurecr.io/example-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        http_ports        = [8080, 8081], health_port = 8081
        cpu               = 0.5, memory = "1Gi", min_replicas = 1, max_replicas = 1
        environment       = { Auth__Authorization__Product = "hexagon-foreign", Auth__Authorization__ResourceServerId = "00000000-0000-4000-8000-000000000001", Auth__Authorization__ClientId = "hexagon-example-dev-authorization" }
        secret_references = { Auth__Authorization__ClientSecret = { secret_uri = "https://examplevault.vault.azure.net/secrets/authorization-client/44444444444444444444444444444444", vault_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-example-dev-hosting/providers/Microsoft.KeyVault/vaults/examplevault" } }
      }
    }
  }
  expect_failures = [var.workloads]
}

run "reject_authorization_missing_credential" {
  command = plan
  variables {
    workloads = {
      api = {
        name              = "example-dev-api", kind = "api", image = "exampledev0001.azurecr.io/example-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        http_ports        = [8080, 8081], health_port = 8081
        cpu               = 0.5, memory = "1Gi", min_replicas = 1, max_replicas = 1
        environment       = { Auth__Authorization__Product = "hexagon-example", Auth__Authorization__ResourceServerId = "00000000-0000-4000-8000-000000000001", Auth__Authorization__ClientId = "hexagon-example-dev-authorization" }
        secret_references = {}
      }
    }
  }
  expect_failures = [var.workloads]
}
