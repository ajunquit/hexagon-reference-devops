variable "product" {
  description = "Stable product identifier."
  type        = string
}

variable "environment" {
  description = "Environment represented by this root module."
  type        = string

  validation {
    condition     = var.environment == "dev"
    error_message = "The dev root only accepts the dev environment."
  }
}

variable "region" {
  description = "AWS region for environment resources."
  type        = string
}

variable "kms_alias_name" {
  description = "KMS alias name without alias/ for SNS topic encryption."
  type        = string
}

variable "tags" {
  description = "Additional resource tags."
  type        = map(string)
  default     = {}
}

variable "destinations" {
  description = "SNS topic policies derived from the backend contract."
  type = map(object({
    name        = string
    event_types = set(string)
    publishers  = map(string)
  }))
}

variable "consumers" {
  description = "SQS queue policies derived from the backend contract."
  type = map(object({
    name                              = string
    destination                       = string
    workload                          = string
    role_name                         = string
    routing_mode                      = string
    event_types                       = set(string)
    visibility_timeout_seconds        = number
    message_retention_seconds         = number
    receive_message_wait_time_seconds = number
    retry_visibility_timeout_seconds  = number
    redrive = object({
      enabled                               = bool
      dead_letter_queue_name                = optional(string)
      max_receive_count                     = optional(number)
      dead_letter_message_retention_seconds = optional(number)
    })
  }))
}
