locals {
  keycloak_enabled = var.keycloak != null
  keycloak_role    = "${local.role_prefix}_keycloak"
  # Keycloak answers under /auth on the same CloudFront origin as the SPA and the API.
  keycloak_origin = "${local.web_origin}/auth"
  auth_authority  = local.keycloak_enabled ? "${local.keycloak_origin}/realms/${var.keycloak.realm}" : var.auth.authority
  identity_jobs = local.keycloak_enabled ? {
    keycloak-database = {
      image       = var.bootstrap_image
      command     = ["--prepare-keycloak"]
      environment = { HEXAGON_DATABASE_BOOTSTRAP = jsonencode(merge(local.bootstrap, { purpose = "keycloak", keycloak = { role = local.keycloak_role, passwordSecret = aws_secretsmanager_secret.keycloak["database"].arn, bootstrapSecret = aws_secretsmanager_secret.keycloak["bootstrap"].arn } })) }
      secrets     = local.maintenance_login
    }
  } : {}
}

# Empty containers: the keycloak-database task writes the database and bootstrap administrator passwords.
resource "aws_secretsmanager_secret" "keycloak" {
  for_each                = local.keycloak_enabled ? toset(["database", "bootstrap"]) : toset([])
  name                    = "${var.name_prefix}/keycloak/${each.key}"
  description             = "Keycloak ${each.key} password, written by the keycloak-database task."
  recovery_window_in_days = 0
  tags                    = local.tags
}

resource "aws_iam_role" "keycloak" {
  count                = local.keycloak_enabled ? 1 : 0
  name                 = "${var.name_prefix}-keycloak"
  assume_role_policy   = local.task_trust
  permissions_boundary = var.workload_boundary_arn
  tags                 = local.tags
}

resource "aws_lb_target_group" "keycloak" {
  count                = local.keycloak_enabled ? 1 : 0
  name                 = "${var.name_prefix}-auth"
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.this.id
  deregistration_delay = 30
  health_check {
    path    = "/auth/health/ready"
    port    = "9000"
    matcher = "200"
  }
  tags = local.tags
}
resource "aws_lb_listener_rule" "keycloak" {
  count        = local.keycloak_enabled ? 1 : 0
  listener_arn = aws_lb_listener.http.arn
  priority     = 20
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.keycloak[0].arn
  }
  condition {
    path_pattern { values = ["/auth/*"] }
  }
  tags = local.tags
}

resource "aws_ecs_task_definition" "keycloak" {
  count                    = var.keycloak_rollout_enabled ? 1 : 0
  family                   = "${var.name_prefix}-auth"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.execution["keycloak"].arn
  task_role_arn            = aws_iam_role.keycloak[0].arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name         = "keycloak"
    image        = var.keycloak.image
    essential    = true
    command      = ["start"]
    portMappings = [{ containerPort = 8080, protocol = "tcp" }, { containerPort = 9000, protocol = "tcp" }]
    environment = [for name, value in {
      KC_DB                       = "postgres"
      KC_DB_URL                   = "jdbc:postgresql://${local.database_host}:${local.database_port}/${var.database_name}?sslmode=require"
      KC_DB_SCHEMA                = "keycloak"
      KC_DB_USERNAME              = local.keycloak_role
      KC_DB_POOL_INITIAL_SIZE     = "1"
      KC_DB_POOL_MIN_SIZE         = "1"
      KC_DB_POOL_MAX_SIZE         = "5"
      KC_HTTP_RELATIVE_PATH       = "/auth"
      KC_HOSTNAME                 = local.keycloak_origin
      KC_HOSTNAME_STRICT          = "true"
      KC_PROXY_HEADERS            = "xforwarded"
      KC_HTTP_ENABLED             = "true"
      KC_HEALTH_ENABLED           = "true"
      KC_CACHE                    = "local"
      KC_BOOTSTRAP_ADMIN_USERNAME = var.keycloak.bootstrap_user
    } : { name = name, value = value }]
    secrets = [
      { name = "KC_DB_PASSWORD", valueFrom = aws_secretsmanager_secret.keycloak["database"].arn },
      { name = "KC_BOOTSTRAP_ADMIN_PASSWORD", valueFrom = aws_secretsmanager_secret.keycloak["bootstrap"].arn }
    ]
    logConfiguration = local.log_configuration["keycloak"]
  }])
  tags = local.tags
}

resource "aws_ecs_service" "keycloak" {
  count                             = var.keycloak_rollout_enabled ? 1 : 0
  name                              = "${var.name_prefix}-auth"
  cluster                           = aws_ecs_cluster.this.id
  task_definition                   = aws_ecs_task_definition.keycloak[0].arn
  desired_count                     = 1
  launch_type                       = "FARGATE"
  enable_execute_command            = false
  propagate_tags                    = "SERVICE"
  health_check_grace_period_seconds = 600
  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = true
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.keycloak[0].arn
    container_name   = "keycloak"
    container_port   = 8080
  }
  tags       = local.tags
  depends_on = [aws_lb_listener_rule.keycloak, aws_iam_role_policy.execution_secrets, aws_ecs_task_definition.maintenance]
}
