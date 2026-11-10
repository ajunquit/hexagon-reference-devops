output "workload_identities" {
  description = "Existing messaging policies can use these workload principals without granting Manage."
  value       = { for id, identity in azurerm_user_assigned_identity.workload : id => { id = identity.id, principal_id = identity.principal_id, client_id = identity.client_id, database_role = identity.name } }
}
output "database_bootstrap" { value = local.bootstrap }
output "maintenance_jobs" { value = { for id, job in azurerm_container_app_job.maintenance : id => { id = job.id, name = job.name } } }
output "registry" { value = { id = azurerm_container_registry.this.id, login_server = azurerm_container_registry.this.login_server } }
output "web" { value = { id = azurerm_static_web_app.this.id, url = "https://${azurerm_static_web_app.this.default_host_name}" } }
output "api_url" { value = var.application_rollout_enabled ? "https://${azurerm_container_app.workload[local.api_id].ingress[0].fqdn}/api/v1" : null }
output "frontend_authentication" { value = { authority = var.auth.authority, clientId = var.auth.client_id, scope = "openid profile email ${var.auth.api_scope}" } }
