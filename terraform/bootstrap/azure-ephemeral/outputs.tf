output "identity" {
  value = {
    client_id    = azurerm_user_assigned_identity.deployment.client_id
    principal_id = azurerm_user_assigned_identity.deployment.principal_id
    id           = azurerm_user_assigned_identity.deployment.id
  }
}
output "container" { value = azurerm_storage_container.instance.name }
output "github_environment" { value = "${var.environment}-${var.instance_id}" }
