output "environments" {
  description = "Non-secret deployment bindings; bootstrap identities cannot access another environment's container."
  value = { for environment, identity in azurerm_user_assigned_identity.deployment : environment => {
    client_id       = identity.client_id
    principal_id    = identity.principal_id
    identity_id     = identity.id
    state_container = var.environments[environment].state_container
  } }
}

output "delegation_condition" { value = local.delegation_condition }
