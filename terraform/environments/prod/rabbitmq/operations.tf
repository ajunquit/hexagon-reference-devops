variable "operations" {
  description = "Validated phase 8 operator permissions; alert rules are deployed to Prometheus separately."
  type = object({
    notification_targets = list(string)
    operator_identities  = map(string)
    consumers = map(object({
      backlog_threshold          = number
      replay_enabled             = optional(bool, false)
      dead_letter_threshold      = optional(number)
      oldest_message_age_seconds = optional(number)
    }))
  })
  default = { notification_targets = [], operator_identities = {}, consumers = {} }
}
