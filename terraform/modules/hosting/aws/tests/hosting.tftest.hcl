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
      name = "example-dev-api", kind = "api", image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/example-dev-0001/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      http_ports = [8080, 8081], health_port = 8081, environment = {}, secret_references = {
        ExternalApi__ApiKey = { secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:example/external-api-AbCdEf" }
      }
      cpu = 512, memory = 1024, min_replicas = 1, max_replicas = 2
    }
    worker = {
      name       = "example-dev-worker", kind = "consumer", image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/example-dev-0001/worker@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      http_ports = [8081], health_port = 8081, environment = {}, secret_references = {}
      cpu        = 256, memory = 512, min_replicas = 1, max_replicas = 1
    }
  }
  migration_workload = "api"
  bootstrap_image    = "123456789012.dkr.ecr.us-east-1.amazonaws.com/example-dev-0001/database-bootstrap@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  tags               = {}
}

run "the_initial_state_creates_private_data_and_no_workloads" {
  assert {
    condition     = length(aws_ecs_service.workload) == 0 && length(aws_ecs_task_definition.workload) == 0 && length(aws_ecs_task_definition.maintenance) == 0
    error_message = "The initial state must not run workloads or maintenance tasks."
  }
  assert {
    condition = (!aws_db_instance.this.publicly_accessible && aws_db_instance.this.storage_encrypted &&
      aws_db_instance.this.manage_master_user_password && !aws_db_instance.this.iam_database_authentication_enabled &&
    aws_db_instance.this.engine_version == "17" && !aws_db_instance.this.multi_az && aws_db_instance.this.skip_final_snapshot)
    error_message = "PostgreSQL must be private, encrypted, with an RDS-managed administrator secret, single-zone and disposable in dev."
  }
  assert {
    condition     = length(aws_route_table.database.route) == 0 && one(aws_route_table.public.route).gateway_id == aws_internet_gateway.this.id
    error_message = "Only the public subnets route to the internet gateway; the database has no route out."
  }
  assert {
    condition     = aws_lb.this.internal && aws_vpc_security_group_ingress_rule.load_balancer_from_cloudfront.prefix_list_id == "pl-3b927c52"
    error_message = "The load balancer must be internal and reachable only from CloudFront."
  }
  assert {
    condition = (aws_s3_bucket_public_access_block.web.block_public_acls && aws_s3_bucket_public_access_block.web.block_public_policy &&
    aws_s3_bucket_public_access_block.web.restrict_public_buckets && aws_s3_bucket_public_access_block.web.ignore_public_acls)
    error_message = "The SPA bucket must stay private behind CloudFront."
  }
  assert {
    condition     = alltrue([for repository in aws_ecr_repository.this : repository.image_tag_mutability == "IMMUTABLE"]) && toset(keys(aws_ecr_repository.this)) == toset(["example-dev-0001/api", "example-dev-0001/worker", "example-dev-0001/database-bootstrap"])
    error_message = "Each artifact needs an immutable repository of this environment."
  }
  assert {
    condition     = length(aws_secretsmanager_secret.workload_connection) == 2 && alltrue([for secret in aws_secretsmanager_secret.workload_connection : secret.recovery_window_in_days == 0])
    error_message = "Each workload gets an empty connection secret that dev can retire immediately."
  }
  assert {
    condition     = [for behavior in aws_cloudfront_distribution.web.ordered_cache_behavior : behavior.path_pattern] == ["/api/*"]
    error_message = "Without integrated Keycloak, CloudFront routes only the API to the applications."
  }
}

run "maintenance_tasks_precede_the_rollout" {
  variables { maintenance_jobs_enabled = true }
  assert {
    condition     = toset(keys(aws_ecs_task_definition.maintenance)) == toset(["database-credentials", "migrations", "database-access"]) && length(aws_ecs_service.workload) == 0
    error_message = "Database credentials, migrations and database access must exist before any workload."
  }
  assert {
    condition = (jsondecode(aws_ecs_task_definition.maintenance["database-credentials"].container_definitions)[0].command == ["--prepare-credentials"] &&
      jsondecode(aws_ecs_task_definition.maintenance["database-access"].container_definitions)[0].command == [] &&
    jsondecode(aws_ecs_task_definition.maintenance["database-access"].container_definitions)[0].secrets == [{ name = "HEXAGON_DATABASE_MAINTENANCE", valueFrom = aws_secretsmanager_secret.maintenance_connection.arn }])
    error_message = "Only database-credentials uses the master user; the runtime grants run with the maintenance login."
  }
  assert {
    condition     = contains(jsondecode(aws_iam_role_policy.maintenance_writes_connections.policy).Statement[0].Action, "secretsmanager:GetSecretValue")
    error_message = "The maintenance tasks read their secrets to keep existing credentials."
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.maintenance["migrations"].container_definitions)[0].secrets[0].valueFrom == aws_secretsmanager_secret.maintenance_connection.arn
    error_message = "Migrations connect with the maintenance connection secret."
  }
  assert {
    condition = (jsondecode(aws_ecs_task_definition.maintenance["database-credentials"].container_definitions)[0].secrets[1].valueFrom ==
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!db-0001-AbCdEf:password::" &&
    jsondecode(jsondecode(aws_ecs_task_definition.maintenance["database-credentials"].container_definitions)[0].environment[0].value).provider == "aws")
    error_message = "Database access reads the administrator from the RDS-managed secret, never from Terraform."
  }
  assert {
    condition     = aws_ecs_task_definition.maintenance["migrations"].task_role_arn == aws_iam_role.maintenance.arn && jsondecode(aws_ecs_task_definition.maintenance["migrations"].container_definitions)[0].command == ["--migrate-only"]
    error_message = "Migrations run with the maintenance role and the API artifact."
  }
}

run "the_rollout_serves_the_api_behind_cloudfront" {
  variables {
    maintenance_jobs_enabled    = true
    application_rollout_enabled = true
  }
  assert {
    condition     = length(aws_ecs_service.workload) == 2 && length(aws_ecs_service.workload["api"].load_balancer) == 1 && length(aws_ecs_service.workload["worker"].load_balancer) == 0
    error_message = "Only the API is registered in the load balancer."
  }
  assert {
    condition     = alltrue([for service in aws_ecs_service.workload : service.network_configuration[0].assign_public_ip && service.network_configuration[0].security_groups == toset([aws_security_group.tasks.id])])
    error_message = "Without NAT, tasks need a public address and the security group that only accepts the load balancer."
  }
  assert {
    condition     = contains([for variable in jsondecode(aws_ecs_task_definition.workload["api"].container_definitions)[0].environment : variable.value if variable.name == "AllowedOrigins"], "https://d111111abcdef8.cloudfront.net")
    error_message = "The API accepts its own CloudFront origin."
  }
  assert {
    condition     = toset([for secret in jsondecode(aws_ecs_task_definition.workload["api"].container_definitions)[0].secrets : secret.name]) == toset(["ExternalApi__ApiKey", "ConnectionStrings__HexagonExampleDb"])
    error_message = "Credentials reach the container only as Secrets Manager references."
  }
  assert {
    condition     = keys(aws_appautoscaling_policy.workload_cpu) == ["api"] && aws_appautoscaling_target.workload["worker"].max_capacity == 1
    error_message = "Only workloads with room to grow get a scaling policy."
  }
  assert {
    condition     = output.api_url == "https://d111111abcdef8.cloudfront.net/api/v1"
    error_message = "The API is published under the CloudFront origin."
  }
}

run "every_role_carries_the_workload_boundary_inside_a_reservation" {
  variables {
    workload_boundary_arn    = "arn:aws:iam::123456789012:policy/hexagon-workload-boundary"
    maintenance_jobs_enabled = true
  }
  assert {
    condition = alltrue(concat(
      [for role in values(aws_iam_role.workload) : role.permissions_boundary == "arn:aws:iam::123456789012:policy/hexagon-workload-boundary"],
      [for role in values(aws_iam_role.execution) : role.permissions_boundary == "arn:aws:iam::123456789012:policy/hexagon-workload-boundary"],
      [aws_iam_role.maintenance.permissions_boundary == "arn:aws:iam::123456789012:policy/hexagon-workload-boundary"]
    ))
    error_message = "A reservation only lets the deployment create roles bounded by aws-access (ADR 0025)."
  }
}

run "every_response_carries_the_security_headers" {
  assert {
    condition = (aws_cloudfront_response_headers_policy.security.security_headers_config[0].content_type_options[0].override &&
      aws_cloudfront_response_headers_policy.security.security_headers_config[0].referrer_policy[0].referrer_policy == "no-referrer" &&
    one(aws_cloudfront_distribution.web.default_cache_behavior).response_headers_policy_id == aws_cloudfront_response_headers_policy.security.id)
    error_message = "The SPA and the API must answer with nosniff and no-referrer."
  }
}
