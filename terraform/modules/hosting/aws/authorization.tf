locals {
  authorization_environment = { for name, value in var.workloads[var.migration_workload].environment : name => value if startswith(name, "Auth__Authorization__") }
  authorization_enabled     = length(local.authorization_environment) > 0
  authorization_secret      = try(var.workloads[var.migration_workload].secret_references["Auth__Authorization__ClientSecret"].secret_arn, null)
  authorization_task = {
    image       = var.workloads[var.migration_workload].image
    command     = ["--migrate-only", "--reconcile-auth-authorization", "--provision-auth-authorization"]
    environment = merge(local.jobs.migrations.environment, local.authorization_environment)
    secrets     = concat(local.jobs.migrations.secrets, [{ name = "Auth__Authorization__ClientSecret", valueFrom = local.authorization_secret }])
  }
  authorization_jobs = local.authorization_enabled ? merge(
    { authorization = local.authorization_task },
    var.acceptance_fixture == null ? {} : { acceptance-authorization = local.authorization_task }
  ) : {}
}
