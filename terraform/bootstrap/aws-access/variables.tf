variable "region" {
  description = "AWS region of the account bootstrap."
  type        = string
}

variable "github_oidc_provider_arn" {
  description = "Existing GitHub OIDC provider of the account; null creates it. There is one per account."
  type        = string
  default     = null
  validation {
    condition     = var.github_oidc_provider_arn == null || can(regex("^arn:aws:iam::[0-9]{12}:oidc-provider/token[.]actions[.]githubusercontent[.]com$", var.github_oidc_provider_arn))
    error_message = "Use the ARN of the token.actions.githubusercontent.com provider."
  }
}

variable "workload_boundary_name" {
  description = "Permissions boundary that every role created by an environment must carry."
  type        = string
  default     = "hexagon-workload-boundary"
  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@_-]{1,128}$", var.workload_boundary_name))
    error_message = "Invalid IAM policy name."
  }
}

variable "tags" {
  description = "Tags of the account bootstrap resources."
  type        = map(string)
  default     = {}
}
