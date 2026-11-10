variable "operations" {
  description = "Optional per-consumer alert policy; application workload permissions remain unchanged."
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

  validation {
    condition = length(var.operations.consumers) == 0 ? length(var.operations.operator_identities) == 0 : (
      toset(keys(var.operations.consumers)) == toset(keys(var.consumers)) &&
      toset(keys(var.operations.operator_identities)) == toset(keys(var.consumers)) &&
      length(distinct(values(var.operations.operator_identities))) == length(var.operations.operator_identities)
    )
    error_message = "An operations policy must cover every consumer with a distinct operator identity."
  }

  validation {
    condition = alltrue([
      for policy in values(var.operations.consumers) :
      policy.backlog_threshold >= 1 &&
      (policy.dead_letter_threshold == null ? true : policy.dead_letter_threshold >= 1)
    ])
    error_message = "Alert thresholds must be positive."
  }
}

locals {
  operations_signals = merge([
    for id, policy in var.operations.consumers : merge({
      "${id}/backlog" = {
        queue_name = var.consumers[id].name
        metric     = "ApproximateNumberOfMessagesVisible"
        threshold  = policy.backlog_threshold
      }
      "${id}/age" = {
        queue_name = var.consumers[id].name
        metric     = "ApproximateAgeOfOldestMessage"
        threshold  = policy.oldest_message_age_seconds
      }
      }, var.consumers[id].redrive.enabled ? {
      "${id}/dead-letter" = {
        queue_name = var.consumers[id].redrive.dead_letter_queue_name
        metric     = "ApproximateNumberOfMessagesVisible"
        threshold  = policy.dead_letter_threshold
      }
    } : {})
  ]...)
}

resource "aws_cloudwatch_metric_alarm" "messaging" {
  for_each = local.operations_signals

  alarm_name          = "${each.value.queue_name}-${substr(sha1(each.key), 0, 12)}"
  alarm_description   = "Hexagon messaging ${each.key}; follow the messaging operations runbook."
  namespace           = "AWS/SQS"
  metric_name         = each.value.metric
  dimensions          = { QueueName = each.value.queue_name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = each.value.threshold
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.operations.notification_targets
  ok_actions          = var.operations.notification_targets
  tags                = var.tags

  lifecycle {
    precondition {
      condition     = length(var.operations.notification_targets) > 0 && toset(keys(var.operations.consumers)) == toset(keys(var.consumers))
      error_message = "Operations require notification targets and an exact consumer policy."
    }
    precondition {
      condition     = each.value.threshold != null
      error_message = "Every enabled metric requires a threshold."
    }
  }
}

resource "aws_iam_role_policy" "operations" {
  for_each = var.operations.operator_identities

  name = "hexagon-messaging-operations-${substr(sha1(each.key), 0, 12)}"
  role = each.value
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect   = "Allow"
        Action   = ["sqs:GetQueueAttributes"]
        Resource = [aws_sqs_queue.this[each.key].arn]
      }
      ], var.consumers[each.key].redrive.enabled ? [
      {
        Effect   = "Allow"
        Action   = var.operations.consumers[each.key].replay_enabled ? ["sqs:GetQueueAttributes", "sqs:ReceiveMessage", "sqs:ChangeMessageVisibility", "sqs:DeleteMessage"] : ["sqs:GetQueueAttributes"]
        Resource = [aws_sqs_queue.dead_letter[each.key].arn]
      }] : [], var.consumers[each.key].redrive.enabled && var.operations.consumers[each.key].replay_enabled ? [
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = [aws_sqs_queue.this[each.key].arn]
      }
    ] : [])
  })

  lifecycle {
    precondition {
      condition     = !contains([for consumer in values(var.consumers) : consumer.role_name], each.value) && !contains(flatten([for destination in values(var.destinations) : values(destination.publishers)]), each.value)
      error_message = "Operations roles must be separate from application workloads."
    }
  }
}
