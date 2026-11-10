variable "resource_group_name" {
  description = "Name of the existing resource group that owns the Service Bus namespace."
  type        = string
}

variable "location" {
  description = "Azure region for the Service Bus namespace."
  type        = string
}

variable "namespace" {
  description = "Service Bus namespace policy. Local authentication is always disabled."
  type = object({
    name                          = string
    sku                           = string
    capacity                      = optional(number)
    public_network_access_enabled = bool
  })

  validation {
    condition     = contains(["Standard", "Premium"], var.namespace.sku)
    error_message = "The namespace SKU must be Standard or Premium because topics are required."
  }

  validation {
    condition = (
      var.namespace.sku == "Premium" ||
      var.namespace.capacity == null
    )
    error_message = "Namespace capacity can only be set for the Premium SKU."
  }

  validation {
    condition = (
      var.namespace.capacity == null ||
      contains([1, 2, 4, 8, 16], var.namespace.capacity)
    )
    error_message = "Premium namespace capacity must be 1, 2, 4, 8, or 16 messaging units."
  }
}

variable "destinations" {
  description = "Logical destinations mapped to physical topics and publisher identities."
  type = map(object({
    name                                    = string
    default_message_ttl                     = string
    duplicate_detection_enabled             = bool
    duplicate_detection_history_time_window = string
    event_types                             = set(string)
    publishers                              = map(string)
  }))

  validation {
    condition     = length(var.destinations) > 0
    error_message = "At least one destination is required."
  }
}

variable "consumers" {
  description = "Logical consumers mapped to subscriptions, routing, and receiver identities."
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

  validation {
    condition = alltrue([
      for consumer in values(var.consumers) :
      contains(["all", "include"], consumer.routing_mode)
    ])
    error_message = "Each consumer routing_mode must be all or include."
  }

  validation {
    condition = alltrue([
      for consumer in values(var.consumers) :
      consumer.routing_mode == "include" ? length(consumer.event_types) > 0 : length(consumer.event_types) == 0
    ])
    error_message = "Include routing requires event types; all routing must not declare them."
  }
}

variable "tags" {
  description = "Tags applied to the namespace."
  type        = map(string)
  default     = {}
}
