variable "region" {
  description = "AWS region for SNS and SQS resources."
  type        = string
}

variable "kms_alias_name" {
  description = "KMS alias name without alias/ for SNS topic encryption."
  type        = string

  validation {
    condition = (
      can(regex("^[A-Za-z0-9/_-]{1,240}$", var.kms_alias_name)) &&
      !startswith(var.kms_alias_name, "alias/")
    )
    error_message = "The KMS alias name must omit alias/ and contain only supported characters."
  }
}

variable "destinations" {
  description = "Logical destinations mapped to standard SNS topics and publisher IAM roles."
  type = map(object({
    name        = string
    event_types = set(string)
    publishers  = map(string)
  }))

  validation {
    condition     = length(var.destinations) > 0
    error_message = "At least one destination is required."
  }
}

variable "consumers" {
  description = "Logical consumers mapped to standard SQS queues and receiver IAM roles."
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

  validation {
    condition = alltrue([
      for consumer in values(var.consumers) :
      consumer.redrive.enabled ? (
        consumer.redrive.dead_letter_queue_name != null &&
        consumer.redrive.max_receive_count != null &&
        consumer.redrive.dead_letter_message_retention_seconds != null
        ) : (
        consumer.redrive.dead_letter_queue_name == null &&
        consumer.redrive.max_receive_count == null &&
        consumer.redrive.dead_letter_message_retention_seconds == null
      )
    ])
    error_message = "Redrive settings must be complete when enabled and absent when disabled."
  }
}

variable "tags" {
  description = "Tags applied to topics and queues."
  type        = map(string)
  default     = {}
}
