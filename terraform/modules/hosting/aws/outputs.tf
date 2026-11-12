output "workload_roles" {
  description = "Existing messaging policies can attach to these task roles without granting Manage."
  value       = { for id, role in aws_iam_role.workload : id => { arn = role.arn, name = role.name, database_role = local.bootstrap.workloads[id].role } }
}
output "database_bootstrap" { value = local.bootstrap }
output "maintenance_tasks" {
  description = "Task definitions that delivery runs once, in order, with the network below."
  value       = { for id, task in aws_ecs_task_definition.maintenance : id => { arn = task.arn, family = task.family } }
}
output "task_network" {
  value = { cluster = aws_ecs_cluster.this.name, subnets = aws_subnet.public[*].id, security_groups = [aws_security_group.tasks.id], assign_public_ip = true }
}
output "registry" {
  value = { url = local.registry, repositories = { for name, repository in aws_ecr_repository.this : name => repository.repository_url } }
}
output "web" {
  value = { bucket = aws_s3_bucket.web.bucket, distribution_id = aws_cloudfront_distribution.web.id, url = local.web_origin }
}
output "api_url" { value = var.application_rollout_enabled ? "${local.web_origin}/api/v1" : null }
output "frontend_authentication" { value = { authority = local.auth_authority, clientId = var.auth.client_id, scope = "openid profile email ${var.auth.api_scope}" } }

output "keycloak" {
  value = local.keycloak_enabled ? {
    service   = var.keycloak_rollout_enabled ? aws_ecs_service.keycloak[0].name : null
    origin    = local.keycloak_origin
    authority = local.auth_authority
    role      = local.keycloak_role
    secrets   = { for name, secret in aws_secretsmanager_secret.keycloak : name => secret.arn }
  } : null
}
