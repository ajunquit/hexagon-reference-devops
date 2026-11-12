mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_data "aws_ec2_managed_prefix_list" {
    defaults = { id = "pl-3b927c52" }
  }
  mock_resource "aws_db_instance" {
    defaults = {
      address            = "example-dev-0001-postgres.abcdefghijkl.us-east-1.rds.amazonaws.com"
      master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!db-0001-AbCdEf", kms_key_id = "", secret_status = "active" }]
    }
  }
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/example-dev-0001-alb/0123456789abcdef", dns_name = "internal-example-dev-0001-alb-123.us-east-1.elb.amazonaws.com" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/example-dev-0001-api/0123456789abcdef" }
  }
  mock_resource "aws_lb_listener" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/example-dev-0001-alb/0123456789abcdef/0123456789abcdef" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/example-dev-0001-role" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:example-dev-0001/database/workload-AbCdEf" }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = { arn = "arn:aws:ecs:us-east-1:123456789012:task-definition/example-dev-0001:1" }
  }
  mock_resource "aws_ecs_cluster" {
    defaults = { arn = "arn:aws:ecs:us-east-1:123456789012:cluster/example-dev-0001", id = "arn:aws:ecs:us-east-1:123456789012:cluster/example-dev-0001" }
  }
  mock_resource "aws_cloudfront_function" {
    defaults = { arn = "arn:aws:cloudfront::123456789012:function/example-dev-0001-spa" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::example-dev-0001-web-123456789012", bucket_regional_domain_name = "example-dev-0001-web-123456789012.s3.us-east-1.amazonaws.com" }
  }
  mock_resource "aws_cloudfront_distribution" {
    defaults = { domain_name = "d111111abcdef8.cloudfront.net", arn = "arn:aws:cloudfront::123456789012:distribution/E2EXAMPLE" }
  }
}


override_resource {
  target = aws_secretsmanager_secret.maintenance_connection
  values = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:example-dev-0001/database/maintenance-AbCdEf" }
}

override_resource {
  target = aws_secretsmanager_secret.keycloak["database"]
  values = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:example-dev-0001/keycloak/database-AbCdEf" }
}
override_resource {
  target = aws_secretsmanager_secret.keycloak["bootstrap"]
  values = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:example-dev-0001/keycloak/bootstrap-AbCdEf" }
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
  auth                     = { authority = null, client_id = "example-web", audience = "example-api", api_scope = "example_api.all" }
  keycloak                 = { image = "quay.io/keycloak/keycloak@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", realm = "hexagon", bootstrap_user = "bootstrap-admin" }
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

run "keycloak_database_is_prepared_before_keycloak_runs" {
  variables { maintenance_jobs_enabled = true }
  assert {
    condition     = contains(keys(aws_ecs_task_definition.maintenance), "keycloak-database") && length(aws_ecs_service.keycloak) == 0
    error_message = "The identity database must be prepared before Keycloak starts."
  }
  assert {
    condition     = toset(keys(aws_secretsmanager_secret.keycloak)) == toset(["database", "bootstrap"]) && length(aws_iam_role_policy.execution_secrets["maintenance"].policy) > 0
    error_message = "Keycloak passwords live in empty Secrets Manager containers that the preparation task fills."
  }
}

run "keycloak_answers_under_auth_on_the_same_origin" {
  variables {
    maintenance_jobs_enabled    = true
    keycloak_rollout_enabled    = true
    application_rollout_enabled = true
  }
  assert {
    condition     = length(aws_ecs_service.keycloak) == 1 && [for behavior in aws_cloudfront_distribution.web.ordered_cache_behavior : behavior.path_pattern] == ["/api/*", "/auth/*"]
    error_message = "CloudFront routes /auth to Keycloak next to the API."
  }
  assert {
    condition     = output.frontend_authentication.authority == "https://d111111abcdef8.cloudfront.net/auth/realms/hexagon" && output.keycloak.origin == "https://d111111abcdef8.cloudfront.net/auth"
    error_message = "The issuer is the CloudFront origin under /auth."
  }
  assert {
    condition     = contains([for variable in jsondecode(aws_ecs_task_definition.keycloak[0].container_definitions)[0].environment : variable.value if variable.name == "KC_HTTP_RELATIVE_PATH"], "/auth")
    error_message = "Keycloak serves under /auth."
  }
  assert {
    condition     = toset([for secret in jsondecode(aws_ecs_task_definition.keycloak[0].container_definitions)[0].secrets : secret.valueFrom]) == toset([for secret in aws_secretsmanager_secret.keycloak : secret.arn])
    error_message = "Keycloak reads its passwords only from its own secrets."
  }
}
