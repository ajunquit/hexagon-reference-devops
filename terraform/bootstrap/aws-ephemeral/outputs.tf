output "role_arn" { value = aws_iam_role.deployment.arn }
output "name_prefix" { value = local.name_prefix }
output "github_environment" { value = "${var.environment}-${var.instance_id}" }
output "state_prefix" { value = local.state_path }
output "instance_tags" { value = local.instance_tags }
