variable "product" {
  description = "Stable product identifier."
  type        = string
}

variable "environment" {
  description = "Environment represented by this root module."
  type        = string

  validation {
    condition     = var.environment == "prod"
    error_message = "The prod root only accepts the prod environment."
  }
}

variable "location" {
  description = "Azure region for environment resources."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group owned by platform bootstrap for this product environment."
  type        = string
}

variable "tags" {
  description = "Additional resource tags."
  type        = map(string)
  default     = {}
}

variable "namespace" {
  description = "Azure Service Bus namespace policy."
  type = object({
    name                          = string
    sku                           = string
    capacity                      = optional(number)
    public_network_access_enabled = bool
  })
}

variable "destinations" {
  description = "Azure Service Bus topic policies derived from the backend contract."
  type = map(object({
    name                                    = string
    default_message_ttl                     = string
    duplicate_detection_enabled             = bool
    duplicate_detection_history_time_window = string
    event_types                             = set(string)
    publishers                              = map(string)
  }))
}

variable "consumers" {
  description = "Azure Service Bus subscription policies derived from the backend contract."
  type = map(object({
    name                              = string
    destination                       = string
    workload                          = string
    principal_id                      = string
    routing_mode                      = string
    event_types                       = set(string)
    max_delivery_count                = number
    lock_duration                     = string
    default_message_ttl               = string
    dead_letter_on_message_expiration = bool
  }))
}
