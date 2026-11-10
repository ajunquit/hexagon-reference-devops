variable "product" { type = string }

variable "subscription_id" {
  type    = string
  default = null
}

variable "tenant_id" {
  type    = string
  default = null
}

variable "resource_group_name" {
  description = "Resource group dedicated to Terraform state."
  type        = string
}

variable "location" {
  description = "Azure region for Terraform state resources."
  type        = string
}

variable "storage_account_name" {
  description = "Globally unique storage account name for Terraform state."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "The storage account name must contain 3 to 24 lowercase letters or digits."
  }
}

variable "container_name" {
  description = "Private blob container that stores isolated Terraform state keys."
  type        = string
  default     = "tfstate"
}

variable "tags" {
  description = "Tags applied to Terraform state resources."
  type        = map(string)
  default     = {}
}

variable "environment_groups" {
  description = "Persistent resource group boundaries owned by bootstrap, never by workload states."
  type        = map(string)
  default     = {}
}

variable "environment_containers" {
  description = "Separate state containers; a key prefix alone is not an authorization boundary."
  type        = map(string)
  default     = {}
}
