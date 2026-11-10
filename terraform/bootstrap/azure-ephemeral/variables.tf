variable "subscription_id" { type = string }
variable "tenant_id" { type = string }
variable "product" { type = string }
variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "staging"], var.environment)
    error_message = "Ephemeral infrastructure is restricted to dev and staging."
  }
}
variable "instance_id" {
  type = string
  validation {
    condition     = can(regex("^run-[1-9][0-9]*-[1-9][0-9]*$", var.instance_id))
    error_message = "An explicit isolated run instance is required."
  }
}
variable "location" { type = string }
variable "state_resource_group" { type = string }
variable "storage_account_name" { type = string }
variable "oidc_prefix" { type = string }
variable "expires_at" { type = number }
variable "roots" {
  type = set(string)
  validation {
    condition     = contains(var.roots, "hosting") && length(setsubtract(var.roots, ["hosting", "messaging"])) == 0
    error_message = "Hosting is required; messaging is optional."
  }
}
