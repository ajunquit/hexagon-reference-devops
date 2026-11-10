variable "rabbitmq_management_endpoint" {
  description = "RabbitMQ management HTTPS endpoint used only to configure the provider."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "rabbitmq_management_username" {
  description = "RabbitMQ topology administrator used only to configure the provider."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "rabbitmq_management_password" {
  description = "RabbitMQ topology administrator password used only to configure the provider."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "virtual_host" {
  description = "Dedicated RabbitMQ virtual host for prod."
  type        = string
}

variable "destinations" {
  description = "Validated RabbitMQ destinations for prod."
  type = map(object({
    name        = string
    event_types = set(string)
    publishers  = map(string)
  }))
}

variable "consumers" {
  description = "Validated RabbitMQ consumers for prod."
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
}
