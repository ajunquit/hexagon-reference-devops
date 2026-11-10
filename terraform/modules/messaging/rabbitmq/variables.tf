variable "virtual_host" {
  description = "Dedicated RabbitMQ virtual host for the product and environment."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$", var.virtual_host))
    error_message = "The virtual host must use a non-empty portable RabbitMQ name."
  }
}

variable "destinations" {
  description = "Logical destinations mapped to durable topic exchanges and publisher users."
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
  description = "Logical consumers mapped to durable quorum queues and existing RabbitMQ users."
  type = map(object({
    name           = string
    destination    = string
    workload       = string
    user_name      = string
    routing_mode   = string
    event_types    = set(string)
    delivery_limit = number
    dead_letter = object({
      enabled       = bool
      exchange_name = optional(string)
      queue_name    = optional(string)
      routing_key   = optional(string)
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
      consumer.delivery_limit >= 1 && consumer.delivery_limit <= 1000 && floor(consumer.delivery_limit) == consumer.delivery_limit
    ])
    error_message = "Each delivery_limit must be an integer between 1 and 1000."
  }

  validation {
    condition = alltrue([
      for consumer in values(var.consumers) :
      consumer.dead_letter.enabled ? (
        consumer.dead_letter.exchange_name != null &&
        consumer.dead_letter.queue_name != null &&
        consumer.dead_letter.routing_key != null
        ) : (
        consumer.dead_letter.exchange_name == null &&
        consumer.dead_letter.queue_name == null &&
        consumer.dead_letter.routing_key == null
      )
    ])
    error_message = "Dead-letter settings must be complete when enabled and absent when disabled."
  }
}
