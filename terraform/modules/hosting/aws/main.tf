data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

locals {
  tags     = merge(var.tags, { product = var.product, environment = var.environment, managed-by = "terraform" })
  registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.region}.amazonaws.com"
  # Valid Fargate memory sizes (MiB) for each CPU size (units).
  fargate_memory = {
    "256"  = [512, 1024, 2048]
    "512"  = [1024, 2048, 3072, 4096]
    "1024" = [2048, 3072, 4096, 5120, 6144, 7168, 8192]
    "2048" = [for gb in range(4, 17) : gb * 1024]
  }
  protected_keys = ["ASPNETCORE_ENVIRONMENT", "HTTP_PORTS", "Auth__Authority", "Auth__Audience", "Auth__ApiScope", "AllowedOrigins", "ConnectionStrings__${var.database_connection_name}"]
  api_id         = one([for id, workload in var.workloads : id if workload.kind == "api"])
  database_host  = aws_db_instance.this.address
  web_origin     = "https://${aws_cloudfront_distribution.web.domain_name}"
  role_prefix    = replace(var.name_prefix, "-", "_")
  # Images live in repositories of this environment: <registry>/<name_prefix>/<artifact>@sha256:...
  repositories = distinct([for image in concat([for workload in values(var.workloads) : workload.image], [var.bootstrap_image]) :
  split("@", trimprefix(image, "${local.registry}/"))[0]])
  log_configuration = {
    for id in concat(keys(var.workloads), ["maintenance", "keycloak"]) : id => {
      logDriver = "awslogs"
      options   = { awslogs-group = aws_cloudwatch_log_group.this.name, awslogs-region = data.aws_region.current.region, awslogs-stream-prefix = id }
    }
  }
  # The database-access task creates one login role per workload and writes its connection string to the
  # empty secret below. Credentials never pass through Terraform plans or state.
  bootstrap = merge({
    provider    = "aws", host = local.database_host, port = 5432, database = var.database_name,
    maintenance = { role = "${local.role_prefix}_maintenance", secret = aws_secretsmanager_secret.maintenance_connection.arn }
    workloads = { for id, workload in var.workloads : id => {
      role = "${local.role_prefix}_${replace(id, "-", "_")}", secret = aws_secretsmanager_secret.workload_connection[id].arn, readDirectory = workload.kind == "api"
    } }
  }, var.messaging_enabled ? {} : { messagingEnabled = false })
  administrator_secret = aws_db_instance.this.master_user_secret[0].secret_arn
  administrator_secrets = [
    { name = "HEXAGON_DATABASE_ADMIN_USERNAME", valueFrom = "${local.administrator_secret}:username::" },
    { name = "HEXAGON_DATABASE_ADMIN_PASSWORD", valueFrom = "${local.administrator_secret}:password::" }
  ]
  auth_environment = { Auth__Authority = local.auth_authority, Auth__Audience = var.auth.audience, Auth__ApiScope = var.auth.api_scope }
  jobs = {
    migrations = {
      image       = var.workloads[var.migration_workload].image
      command     = ["--migrate-only"]
      environment = merge({ ASPNETCORE_ENVIRONMENT = "Production" }, local.auth_environment)
      secrets     = [{ name = "ConnectionStrings__${var.database_connection_name}", valueFrom = aws_secretsmanager_secret.maintenance_connection.arn }]
    }
    database-access = {
      image       = var.bootstrap_image
      command     = []
      environment = { HEXAGON_DATABASE_BOOTSTRAP = jsonencode(local.bootstrap) }
      secrets     = local.administrator_secrets
    }
  }
  acceptance_jobs = var.acceptance_fixture == null ? {} : {
    acceptance-seed = {
      image       = var.workloads[var.migration_workload].image
      command     = ["--seed-acceptance-only"]
      environment = merge(local.jobs.migrations.environment, { HEXAGON_ACCEPTANCE_SEED = jsonencode(var.acceptance_fixture) })
      secrets     = local.jobs.migrations.secrets
    }
  }
  maintenance_tasks = var.maintenance_jobs_enabled ? merge(local.jobs, local.acceptance_jobs, local.identity_jobs) : {}
  task_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ecs-tasks.amazonaws.com" }
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
  # Secrets each execution role may read to start its containers, and nothing else.
  execution_secrets = merge(
    { for id, workload in var.workloads : id => concat([for secret in values(workload.secret_references) : secret.secret_arn], [aws_secretsmanager_secret.workload_connection[id].arn]) },
    { maintenance = [local.administrator_secret, aws_secretsmanager_secret.maintenance_connection.arn] },
    local.keycloak_enabled ? { keycloak = [for secret in aws_secretsmanager_secret.keycloak : secret.arn] } : {}
  )
}

# Network: public subnets for the load balancer and the tasks, without NAT; tasks reach AWS APIs and
# image registries through a public address, and security groups accept no inbound internet traffic.
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = "${var.name_prefix}-vpc" })
}
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name_prefix}-igw" })
}
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false
  tags                    = merge(local.tags, { Name = "${var.name_prefix}-public-${count.index}" })
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = merge(local.tags, { Name = "${var.name_prefix}-public" })
}
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
resource "aws_subnet" "database" {
  count                   = 2
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.database_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false
  tags                    = merge(local.tags, { Name = "${var.name_prefix}-database-${count.index}" })
}
# Only the implicit local route: the database has no path to or from the internet.
resource "aws_route_table" "database" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name_prefix}-database" })
}
resource "aws_route_table_association" "database" {
  count          = 2
  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = aws_route_table.database.id
}
resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-database"
  subnet_ids = aws_subnet.database[*].id
  tags       = local.tags
}

resource "aws_security_group" "load_balancer" {
  name        = "${var.name_prefix}-load-balancer"
  description = "Internal load balancer reached only by CloudFront VPC origins."
  vpc_id      = aws_vpc.this.id
  tags        = local.tags
}
resource "aws_vpc_security_group_ingress_rule" "load_balancer_from_cloudfront" {
  security_group_id = aws_security_group.load_balancer.id
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}
resource "aws_vpc_security_group_egress_rule" "load_balancer_to_tasks" {
  for_each                     = toset(["8080", "8081", "9000"])
  security_group_id            = aws_security_group.load_balancer.id
  referenced_security_group_id = aws_security_group.tasks.id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
}
resource "aws_security_group" "tasks" {
  name        = "${var.name_prefix}-tasks"
  description = "Fargate tasks: inbound only from the load balancer, outbound to AWS APIs and the database."
  vpc_id      = aws_vpc.this.id
  tags        = local.tags
}
resource "aws_vpc_security_group_ingress_rule" "tasks_from_load_balancer" {
  for_each                     = toset(["8080", "8081", "9000"])
  security_group_id            = aws_security_group.tasks.id
  referenced_security_group_id = aws_security_group.load_balancer.id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
}
resource "aws_vpc_security_group_egress_rule" "tasks_outbound" {
  security_group_id = aws_security_group.tasks.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
resource "aws_security_group" "database" {
  name        = "${var.name_prefix}-database"
  description = "PostgreSQL reachable only from the tasks of this environment."
  vpc_id      = aws_vpc.this.id
  tags        = local.tags
}
resource "aws_vpc_security_group_ingress_rule" "database_from_tasks" {
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.tasks.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_db_instance" "this" {
  lifecycle {
    precondition {
      condition     = var.auth.authority != null || local.keycloak_enabled
      error_message = "Choose an external HTTPS issuer or integrated Keycloak."
    }
  }
  identifier                          = "${var.name_prefix}-postgres"
  engine                              = "postgres"
  engine_version                      = "17"
  instance_class                      = var.database_instance_class
  allocated_storage                   = var.database_storage_gb
  storage_type                        = "gp3"
  storage_encrypted                   = true
  db_name                             = var.database_name
  username                            = "${local.role_prefix}_admin"
  manage_master_user_password         = true
  iam_database_authentication_enabled = false
  db_subnet_group_name                = aws_db_subnet_group.this.name
  vpc_security_group_ids              = [aws_security_group.database.id]
  publicly_accessible                 = false
  multi_az                            = var.database_multi_az
  ca_cert_identifier                  = "rds-ca-rsa2048-g1"
  backup_retention_period             = var.environment == "prod" ? 14 : 1
  deletion_protection                 = var.environment == "prod"
  skip_final_snapshot                 = var.environment != "prod"
  final_snapshot_identifier           = var.environment == "prod" ? "${var.name_prefix}-postgres-final" : null
  copy_tags_to_snapshot               = true
  auto_minor_version_upgrade          = true
  apply_immediately                   = var.environment != "prod"
  tags                                = local.tags
}

# Empty containers: the database-access task writes each connection string; Terraform never holds a value.
resource "aws_secretsmanager_secret" "workload_connection" {
  for_each                = var.workloads
  name                    = "${var.name_prefix}/database/${each.key}"
  description             = "Connection string of ${each.value.name}, written by the database-access task."
  recovery_window_in_days = var.environment == "prod" ? 7 : 0
  tags                    = local.tags
}
resource "aws_secretsmanager_secret" "maintenance_connection" {
  name                    = "${var.name_prefix}/database/maintenance"
  description             = "Connection string of the migration task, written by the database-access task."
  recovery_window_in_days = var.environment == "prod" ? 7 : 0
  tags                    = local.tags
}

resource "aws_ecr_repository" "this" {
  for_each             = toset(local.repositories)
  name                 = each.value
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.environment != "prod"
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
  tags = local.tags
  lifecycle {
    precondition {
      condition     = startswith(each.value, "${var.name_prefix}/")
      error_message = "Images must live in repositories of this environment: <registry>/<name_prefix>/<artifact>."
    }
  }
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/hexagon/${var.name_prefix}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

# One task role per workload, without permissions: messaging policies attach to these roles.
resource "aws_iam_role" "workload" {
  for_each           = var.workloads
  name               = "${var.name_prefix}-${substr(sha1(each.key), 0, 10)}"
  assume_role_policy = local.task_trust
  tags               = local.tags
}
resource "aws_iam_role" "maintenance" {
  name               = "${var.name_prefix}-maintenance"
  assume_role_policy = local.task_trust
  tags               = local.tags
}
resource "aws_iam_role_policy" "maintenance_writes_connections" {
  name = "write-connection-secrets"
  role = aws_iam_role.maintenance.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Action = ["secretsmanager:PutSecretValue", "secretsmanager:DescribeSecret"]
      Resource = concat([for secret in aws_secretsmanager_secret.workload_connection : secret.arn], [aws_secretsmanager_secret.maintenance_connection.arn],
      [for secret in aws_secretsmanager_secret.keycloak : secret.arn])
    }]
  })
}
# Execution roles pull images, write logs and read only the secrets of their own containers.
resource "aws_iam_role" "execution" {
  for_each           = local.execution_secrets
  name               = "${var.name_prefix}-run-${substr(sha1(each.key), 0, 10)}"
  assume_role_policy = local.task_trust
  tags               = local.tags
}
resource "aws_iam_role_policy_attachment" "execution" {
  for_each   = local.execution_secrets
  role       = aws_iam_role.execution[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_iam_role_policy" "execution_secrets" {
  for_each = local.execution_secrets
  name     = "read-own-secrets"
  role     = aws_iam_role.execution[each.key].id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = distinct(each.value) }]
  })
}

resource "aws_ecs_cluster" "this" {
  name = var.name_prefix
  setting {
    name  = "containerInsights"
    value = "disabled"
  }
  tags = local.tags
}

# Maintenance tasks are task definitions: delivery runs them once with ecs:RunTask before the rollout.
resource "aws_ecs_task_definition" "maintenance" {
  for_each                 = local.maintenance_tasks
  family                   = "${var.name_prefix}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.execution["maintenance"].arn
  task_role_arn            = aws_iam_role.maintenance.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name             = "maintenance"
    image            = each.value.image
    essential        = true
    command          = each.value.command
    environment      = [for name, value in each.value.environment : { name = name, value = value }]
    secrets          = each.value.secrets
    logConfiguration = local.log_configuration["maintenance"]
  }])
  tags       = local.tags
  depends_on = [aws_ecr_repository.this, aws_iam_role_policy.execution_secrets, aws_iam_role_policy.maintenance_writes_connections]
}

resource "aws_ecs_task_definition" "workload" {
  for_each                 = var.application_rollout_enabled ? var.workloads : {}
  family                   = each.value.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(each.value.cpu)
  memory                   = tostring(each.value.memory)
  execution_role_arn       = aws_iam_role.execution[each.key].arn
  task_role_arn            = aws_iam_role.workload[each.key].arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name         = "application"
    image        = each.value.image
    essential    = true
    portMappings = [for port in each.value.http_ports : { containerPort = port, protocol = "tcp" }]
    environment = [for name, value in merge(each.value.environment, {
      ASPNETCORE_ENVIRONMENT = "Production"
      HTTP_PORTS             = join(";", each.value.http_ports)
    }, each.value.kind == "api" ? merge(local.auth_environment, { AllowedOrigins = local.web_origin }) : {}) : { name = name, value = value }]
    secrets = concat(
      [for name, secret in each.value.secret_references : { name = name, valueFrom = secret.secret_arn }],
      [{ name = "ConnectionStrings__${var.database_connection_name}", valueFrom = aws_secretsmanager_secret.workload_connection[each.key].arn }]
    )
    logConfiguration = local.log_configuration[each.key]
  }])
  lifecycle {
    precondition {
      condition     = length(setintersection(setunion(toset(keys(each.value.environment)), toset(keys(each.value.secret_references))), toset(local.protected_keys))) == 0
      error_message = "Workload bindings cannot override protected hosting or identity settings."
    }
  }
  tags = local.tags
}

resource "aws_ecs_service" "workload" {
  for_each                           = var.application_rollout_enabled ? var.workloads : {}
  name                               = each.value.name
  cluster                            = aws_ecs_cluster.this.id
  task_definition                    = aws_ecs_task_definition.workload[each.key].arn
  desired_count                      = each.value.min_replicas
  launch_type                        = "FARGATE"
  enable_execute_command             = false
  propagate_tags                     = "SERVICE"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = each.value.kind == "api" ? 300 : null
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = true
  }
  dynamic "load_balancer" {
    for_each = each.value.kind == "api" ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.api.arn
      container_name   = "application"
      container_port   = 8080
    }
  }
  lifecycle {
    # The application scaling target owns the replica count after the first rollout.
    ignore_changes = [desired_count]
  }
  tags       = local.tags
  depends_on = [aws_lb_listener_rule.api, aws_iam_role_policy.execution_secrets, aws_iam_role_policy_attachment.execution]
}

resource "aws_appautoscaling_target" "workload" {
  for_each           = var.application_rollout_enabled ? var.workloads : {}
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.workload[each.key].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = each.value.min_replicas
  max_capacity       = each.value.max_replicas
}
resource "aws_appautoscaling_policy" "workload_cpu" {
  for_each           = { for id, workload in(var.application_rollout_enabled ? var.workloads : {}) : id => workload if workload.max_replicas > workload.min_replicas }
  name               = "${each.value.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.workload[each.key].service_namespace
  resource_id        = aws_appautoscaling_target.workload[each.key].resource_id
  scalable_dimension = aws_appautoscaling_target.workload[each.key].scalable_dimension
  target_tracking_scaling_policy_configuration {
    target_value = 70
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
