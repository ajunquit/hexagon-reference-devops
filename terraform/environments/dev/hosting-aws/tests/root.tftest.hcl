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
  target = module.hosting.aws_secretsmanager_secret.maintenance_connection
  values = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:example-dev-0001/database/maintenance-AbCdEf" }
}

# The shape Export-AwsHostingInputs.ps1 writes: no sizes beyond the workloads, rollout disabled.
variables {
  product                  = "hexagon-example"
  environment              = "dev"
  account_id               = "123456789012"
  region                   = "us-east-1"
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
    hexagon-example-api = {
      name       = "example-dev-0", kind = "api", image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/example-dev-0001/hexagon-example-api@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
      http_ports = [8080, 8081], health_port = 8081, environment = {}, secret_references = {}
      cpu        = 256, memory = 512, min_replicas = 1, max_replicas = 1
    }
  }
  migration_workload = "hexagon-example-api"
  bootstrap_image    = "123456789012.dkr.ecr.us-east-1.amazonaws.com/example-dev-0001/database-bootstrap@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  messaging_enabled  = false
  tags               = {}
}

run "unset_sizes_take_the_minimum_defaults_of_the_module" {
  variables {
    database_instance_class = null
    database_storage_gb     = null
    database_multi_az       = null
    log_retention_days      = null
  }
  assert {
    condition     = output.api_url == null && length(output.maintenance_tasks) == 0
    error_message = "The initial state must not expose the API or create maintenance tasks."
  }
  assert {
    condition     = sort(keys(output.registry.repositories)) == tolist(["example-dev-0001/database-bootstrap", "example-dev-0001/hexagon-example-api"])
    error_message = "Each artifact needs its own repository under the environment prefix."
  }
}

run "the_root_rejects_another_environment" {
  command = plan
  variables { environment = "staging" }
  expect_failures = [var.environment]
}

run "the_root_rejects_an_invalid_account" {
  command = plan
  variables { account_id = "12345" }
  expect_failures = [var.account_id]
}

run "the_root_accepts_only_persistent_or_a_reservation_instance" {
  command = plan
  variables { instance_id = "latest" }
  expect_failures = [var.instance_id]
}
