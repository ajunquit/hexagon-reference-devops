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

run "api_only_bootstrap_excludes_outbox_access" {
  command = plan
  variables {
    messaging_enabled = false
    workloads = {
      api = {
        name       = "example-dev-api", kind = "api", image = "exampledev0001.azurecr.io/example-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        http_ports = [8080, 8081], health_port = 8081, environment = {}, secret_references = {}
        cpu        = 0.5, memory = "1Gi", min_replicas = 1, max_replicas = 1
      }
    }
  }
  assert {
    condition     = output.database_bootstrap.messagingEnabled == false && length(output.workload_identities) == 1
    error_message = "The API-only profile must not grant or require an outbox role."
  }
}
run "reject_consumer_without_messaging" {
  command = plan
  variables { messaging_enabled = false }
  expect_failures = [var.messaging_enabled]
}