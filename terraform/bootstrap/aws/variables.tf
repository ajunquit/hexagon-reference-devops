variable "region" {
  description = "AWS region for Terraform state resources."
  type        = string
}

variable "bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "The state bucket name must be a valid lowercase S3 bucket name."
  }
}

variable "kms_alias_name" {
  description = "KMS alias name without the alias/ prefix."
  type        = string

  validation {
    condition = (
      can(regex("^[A-Za-z0-9/_-]{1,240}$", var.kms_alias_name)) &&
      !startswith(var.kms_alias_name, "alias/")
    )
    error_message = "The KMS alias name must omit alias/ and contain only supported characters."
  }
}

variable "tags" {
  description = "Tags applied to Terraform state resources."
  type        = map(string)
  default     = {}
}
