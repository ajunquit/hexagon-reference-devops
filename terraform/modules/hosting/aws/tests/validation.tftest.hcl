mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
}

variables {
  product                  = "hexagon-example"
  environment              = "dev"
  name_prefix              = "example-dev-0001"
  availability_zones       = ["us-east-1a", "us-east-1b"]
  vpc_cidr                 = "10.42.0.0/16"
  public_subnet_cidrs      = ["10.42.0.0/24", "10.42.1.0/24"]
  database_subnet_cidrs    = ["10.42.10.0/24", "10.42.11.0/24"]
  database_name            = "hexagon_example"
  database_connection_name = "HexagonExampleDb"
  auth = {
    authority = "https://auth.example.test/realms/hexagon"
    client_id = "example-web"
    audience  = "example-api"
    api_scope = "example_api.all"
  }
  workloads = {
    api = {
      name       = "example-dev-api", kind = "api", image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/example-dev-0001/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      http_ports = [8080, 8081], health_port = 8081, environment = {}, secret_references = {}
      cpu        = 512, memory = 1024, min_replicas = 1, max_replicas = 1
    }
  }
  migration_workload = "api"
  bootstrap_image    = "123456789012.dkr.ecr.us-east-1.amazonaws.com/example-dev-0001/database-bootstrap@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  tags               = {}
}

run "rejects_a_mutable_image_tag" {
  command = plan
  variables {
    workloads = {
      api = {
        name       = "example-dev-api", kind = "api", image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/example-dev-0001/api:latest"
        http_ports = [8080, 8081], health_port = 8081, environment = {}, secret_references = {}
        cpu        = 512, memory = 1024, min_replicas = 1, max_replicas = 1
      }
    }
  }
  expect_failures = [var.workloads]
}

run "rejects_an_image_of_another_account" {
  command = plan
  variables {
    workloads = {
      api = {
        name       = "example-dev-api", kind = "api", image = "210987654321.dkr.ecr.us-east-1.amazonaws.com/example-dev-0001/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        http_ports = [8080, 8081], health_port = 8081, environment = {}, secret_references = {}
        cpu        = 512, memory = 1024, min_replicas = 1, max_replicas = 1
      }
    }
  }
  expect_failures = [var.workloads]
}

run "rejects_an_invalid_fargate_size" {
  command = plan
  variables {
    workloads = {
      api = {
        name       = "example-dev-api", kind = "api", image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/example-dev-0001/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        http_ports = [8080, 8081], health_port = 8081, environment = {}, secret_references = {}
        cpu        = 256, memory = 4096, min_replicas = 1, max_replicas = 1
      }
    }
  }
  expect_failures = [var.workloads]
}

run "rejects_a_credential_in_plain_environment" {
  command = plan
  variables {
    workloads = {
      api = {
        name       = "example-dev-api", kind = "api", image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/example-dev-0001/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        http_ports = [8080, 8081], health_port = 8081, environment = { ExternalApi__Password = "plain" }, secret_references = {}
        cpu        = 512, memory = 1024, min_replicas = 1, max_replicas = 1
      }
    }
  }
  expect_failures = [var.workloads]
}

run "rejects_a_rollout_before_maintenance" {
  command = plan
  variables { application_rollout_enabled = true }
  expect_failures = [var.application_rollout_enabled]
}

run "rejects_acceptance_fixtures_in_prod" {
  command = plan
  variables {
    environment        = "prod"
    acceptance_fixture = { instanceId = "run-1-1", subjectId = "00000000-0000-4000-8000-000000000001", tenant = "e2e-run-1-1-a", otherTenant = "e2e-run-1-1-b" }
  }
  expect_failures = [var.acceptance_fixture]
}

run "rejects_keycloak_outside_dev" {
  command = plan
  variables {
    environment = "staging"
    auth        = { authority = null, client_id = "example-web", audience = "example-api", api_scope = "example_api.all" }
    keycloak    = { image = "quay.io/keycloak/keycloak@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", realm = "hexagon", bootstrap_user = "bootstrap-admin" }
  }
  expect_failures = [var.keycloak]
}

run "requires_an_issuer_or_integrated_keycloak" {
  command = plan
  variables {
    auth = { authority = null, client_id = "example-web", audience = "example-api", api_scope = "example_api.all" }
  }
  expect_failures = [aws_db_instance.this]
}
