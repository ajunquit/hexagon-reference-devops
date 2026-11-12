output "workload_identities" { value = module.hosting.workload_identities }
output "database_bootstrap" { value = module.hosting.database_bootstrap }
output "maintenance_jobs" { value = module.hosting.maintenance_jobs }
output "registry" { value = module.hosting.registry }
output "web" { value = module.hosting.web }
output "api_url" { value = module.hosting.api_url }
output "frontend_authentication" { value = module.hosting.frontend_authentication }

output "keycloak" { value = module.hosting.keycloak }
