variable "region" { type = string }
variable "product" {
  type = string
  validation {
    condition     = can(regex("^hexagon-[a-z][a-z0-9-]*$", var.product))
    error_message = "Invalid product name."
  }
}
variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "staging"], var.environment)
    error_message = "Ephemeral reservations exist only in dev and staging."
  }
}
variable "instance_id" {
  type = string
  validation {
    condition     = can(regex("^run-[1-9][0-9]{0,19}-[1-9][0-9]{0,3}$", var.instance_id))
    error_message = "Use the run-ID-attempt of the run that originated the reservation."
  }
}
variable "name_prefix_base" {
  description = "Base of the short prefix (ADR 0025): 3 to 12 characters; the reservation appends six hex characters."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,10}[a-z0-9]$", var.name_prefix_base)) && !strcontains(var.name_prefix_base, "--")
    error_message = "Use 3 to 12 lowercase characters, digits or single hyphens."
  }
}
variable "oidc_prefix" {
  description = "repo:<owner>/<repository> of the product DevOps instance."
  type        = string
  validation {
    condition     = can(regex("^repo:[A-Za-z0-9-]+/hexagon-[a-z0-9-]+-devops$", var.oidc_prefix))
    error_message = "Only the DevOps repository of the product can deploy."
  }
}
variable "github_oidc_provider_arn" {
  type = string
  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:oidc-provider/token[.]actions[.]githubusercontent[.]com$", var.github_oidc_provider_arn))
    error_message = "Use the GitHub OIDC provider of aws-access."
  }
}
variable "workload_boundary_arn" {
  type = string
  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:policy/[A-Za-z0-9+=,.@_-]+$", var.workload_boundary_arn))
    error_message = "Use the workload boundary of aws-access."
  }
}
variable "state_bucket" { type = string }
variable "state_kms_key_arn" {
  type = string
  validation {
    condition     = can(regex("^arn:aws:kms:[a-z0-9-]+:[0-9]{12}:key/[0-9a-f-]{36}$", var.state_kms_key_arn))
    error_message = "Use the KMS key of the state bucket."
  }
}
variable "expires_at" {
  description = "Unix UTC time after which Genesis refuses to create; recovery and Apocalypse stay allowed."
  type        = number
}
variable "tags" {
  type    = map(string)
  default = {}
}
