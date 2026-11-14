output "github_oidc_provider_arn" {
  value = var.github_oidc_provider_arn != null ? var.github_oidc_provider_arn : aws_iam_openid_connect_provider.github[0].arn
}

output "workload_boundary_arn" { value = aws_iam_policy.workload_boundary.arn }
