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
    authority = "https://auth.example.test/realms/hexagon"
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
}

run "bootstrap_does_not_enable_application_traffic" {
  command = plan
  variables { maintenance_jobs_enabled = true }
  assert {
    condition     = alltrue([for role in concat(values(azurerm_role_assignment.image_pull), values(azurerm_role_assignment.secret_read)) : role.principal_type == "ServicePrincipal"]) && length(azurerm_role_assignment.secret_read) == 1
    error_message = "Delegated RBAC requests must explicitly identify workload service principals."
  }
  assert {
    condition     = length(azurerm_container_app.workload) == 0 && length(azurerm_container_app_job.maintenance) == 2
    error_message = "Migrations and access bootstrap must precede application rollout."
  }
  assert {
    condition     = !azurerm_postgresql_flexible_server.this.public_network_access_enabled && !azurerm_postgresql_flexible_server.this.authentication[0].password_auth_enabled
    error_message = "PostgreSQL must be private and identity authenticated."
  }
  assert {
    condition     = !azurerm_container_registry.this.admin_enabled && length(azurerm_user_assigned_identity.workload) == 2
    error_message = "Registry credentials and shared workload identities are forbidden."
  }
  assert {
    condition     = azurerm_container_app_job.maintenance["migrations"].template[0].container[0].args == tolist(["--migrate-only"])
    error_message = "The migration job must use the explicit no-server startup mode."
  }
}

run "rollout_exposes_only_api_business_port" {
  command = plan
  variables {
    maintenance_jobs_enabled    = true
    application_rollout_enabled = true
  }
  assert {
    condition     = length(azurerm_container_app.workload) == 2 && length(azurerm_container_app.workload["worker"].ingress) == 0
    error_message = "Worker health must never have public ingress."
  }
  assert {
    condition     = azurerm_container_app.workload["api"].ingress[0].target_port == 8080 && !azurerm_container_app.workload["api"].ingress[0].allow_insecure_connections
    error_message = "Only HTTPS ingress to the API business port is allowed."
  }
  assert {
    condition     = azurerm_container_app.workload["api"].template[0].container[0].readiness_probe[0].port == 8081
    error_message = "Health probes must stay on the internal health port."
  }
}

run "empty_registry_bootstrap_needs_no_container_images" {
  command = plan
  assert {
    condition     = length(azurerm_container_app.workload) == 0 && length(azurerm_container_app_job.maintenance) == 0
    error_message = "The first infrastructure deployment must not pull images from an empty registry."
  }
}

run "rejects_rollout_before_jobs_are_enabled" {
  command = plan
  variables { application_rollout_enabled = true }
  expect_failures = [var.application_rollout_enabled]
}
run "isolated_acceptance_seed" {
  command = plan
  variables {
    maintenance_jobs_enabled = true
    acceptance_fixture       = { instanceId = "run-123-1", subjectId = "55555555-5555-4555-8555-555555555555", tenant = "e2e-run-123-1-a", otherTenant = "e2e-run-123-1-b" }
  }
  assert {
    condition     = length(azurerm_container_app_job.maintenance) == 3 && azurerm_container_app_job.maintenance["acceptance-seed"].template[0].container[0].args == tolist(["--seed-acceptance-only"])
    error_message = "Acceptance must be an explicit maintenance job using the API image."
  }
  assert {
    condition     = azurerm_container_app_job.maintenance["acceptance-seed"].replica_retry_limit == 0 && length(azurerm_container_app_job.maintenance["acceptance-seed"].name) <= 32
    error_message = "Do not retry ambiguous seed jobs or exceed the Azure job name limit."
  }
}
run "reject_production_acceptance" {
  command = plan
  variables {
    environment        = "prod"
    acceptance_fixture = { instanceId = "run-123-1", subjectId = "55555555-5555-4555-8555-555555555555", tenant = "e2e-run-123-1-a", otherTenant = "e2e-run-123-1-b" }
  }
  expect_failures = [var.acceptance_fixture]
}
run "reject_foreign_tenant_fixture" {
  command = plan
  variables {
    acceptance_fixture = { instanceId = "run-123-1", subjectId = "55555555-5555-4555-8555-555555555555", tenant = "existing-tenant", otherTenant = "e2e-run-123-1-b" }
  }
  expect_failures = [var.acceptance_fixture]
}
