# Inputs come from Export-AwsHostingInputs.ps1. The module validates them; this root pins the
# environment and the account, and leaves unset sizes to the module's minimum defaults.
variable "product" { type = string }
variable "environment" {
  type = string
  validation {
    condition     = var.environment == "prod"
    error_message = "This root only accepts the prod environment."
  }
}
variable "account_id" {
  description = "The only AWS account this root may change."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "Use a 12-digit AWS account ID."
  }
}
variable "region" { type = string }
variable "name_prefix" { type = string }
variable "availability_zones" { type = list(string) }
variable "vpc_cidr" { type = string }
variable "public_subnet_cidrs" { type = list(string) }
variable "database_subnet_cidrs" { type = list(string) }
variable "database_name" { type = string }
variable "database_connection_name" { type = string }
variable "database_instance_class" {
  type    = string
  default = null
}
variable "database_storage_gb" {
  type    = number
  default = null
}
variable "database_multi_az" {
  type    = bool
  default = null
}
variable "log_retention_days" {
  type    = number
  default = null
}
variable "messaging_enabled" {
  type    = bool
  default = true
}
variable "auth" {
  type = object({ authority = string, client_id = string, audience = string, api_scope = string })
}
variable "keycloak" {
  type    = object({ image = string, realm = string, bootstrap_user = string })
  default = null
}
variable "keycloak_rollout_enabled" {
  type    = bool
  default = false
}
variable "workloads" {
  type = map(object({
    name        = string, kind = string, image = string,
    http_ports  = list(number), health_port = number,
    environment = map(string), secret_references = map(object({ secret_arn = string })),
    cpu         = number, memory = number, min_replicas = number, max_replicas = number
  }))
}
variable "migration_workload" { type = string }
variable "bootstrap_image" { type = string }
variable "maintenance_jobs_enabled" {
  type    = bool
  default = false
}
variable "application_rollout_enabled" {
  type    = bool
  default = false
}
variable "acceptance_fixture" {
  type    = object({ instanceId = string, subjectId = string, tenant = string, otherTenant = string })
  default = null
}
variable "tags" { type = map(string) }
variable "instance_id" {
  description = "Instance of the lifecycle: persistent, or the run-ID-attempt of an ephemeral reservation."
  type        = string
  default     = "persistent"
  validation {
    condition     = can(regex("^(persistent|run-[1-9][0-9]{0,19}-[1-9][0-9]{0,3})$", var.instance_id))
    error_message = "Use persistent or run-ID-attempt."
  }
}
variable "workload_boundary_arn" {
  type    = string
  default = null
}
