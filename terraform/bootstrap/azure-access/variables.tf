variable "subscription_id" { type = string }
variable "tenant_id" { type = string }
variable "product" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "storage_account_name" { type = string }
variable "oidc_prefix" { type = string }
variable "environments" {
  type = map(object({
    identity_name   = string
    resource_groups = set(string)
    state_container = string
  }))
  validation {
    condition = (
      toset(keys(var.environments)) == toset(["dev", "staging", "prod"]) &&
      length(distinct([for value in values(var.environments) : lower(value.identity_name)])) == 3 &&
      length(distinct([for value in values(var.environments) : lower(value.state_container)])) == 3 &&
      alltrue([for environment, value in var.environments :
        endswith(value.state_container, "-${environment}") &&
        alltrue([for group in value.resource_groups : startswith(group, "rg-${var.product}-${environment}") && group != var.resource_group_name])
      ]) &&
      length(flatten([for value in values(var.environments) : tolist(value.resource_groups)])) ==
      length(distinct(flatten([for value in values(var.environments) : tolist(value.resource_groups)])))
    )
    error_message = "All three environments require separate identities, state containers and resource groups."
  }
}
