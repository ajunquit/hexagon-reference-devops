check "consumer_destinations" {
  assert {
    condition = alltrue([
      for consumer in values(var.consumers) : contains(keys(var.destinations), consumer.destination)
    ])
    error_message = "Every consumer must reference a declared destination."
  }
}

check "consumer_event_types" {
  assert {
    condition = alltrue([
      for consumer in values(var.consumers) :
      consumer.routing_mode == "all" || try(alltrue([
        for event_type in consumer.event_types :
        contains(var.destinations[consumer.destination].event_types, event_type)
      ]), false)
    ])
    error_message = "Every included event type must be published by the consumer destination."
  }
}

check "dead_letter_retention" {
  assert {
    condition = alltrue([
      for consumer in values(local.redrive_consumers) :
      consumer.redrive.dead_letter_message_retention_seconds > consumer.message_retention_seconds
    ])
    error_message = "A dead-letter queue must retain messages longer than its source queue."
  }
}

check "queue_names" {
  assert {
    condition     = length(local.all_queue_names) == length(distinct(local.all_queue_names))
    error_message = "Source and dead-letter queue names must be unique within the AWS account and region."
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_iam_policy_document" "messaging_key" {
  statement {
    sid    = "EnableAccountAdministration"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowSnsEncryption"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["sns.${data.aws_partition.current.dns_suffix}"]
    }

    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey*"
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_kms_key" "messaging" {
  description             = "Encrypts Hexagon SNS integration event topics"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.messaging_key.json
  tags                    = var.tags
}

resource "aws_kms_alias" "messaging" {
  name          = "alias/${var.kms_alias_name}"
  target_key_id = aws_kms_key.messaging.key_id
}

resource "aws_sns_topic" "this" {
  for_each = var.destinations

  name              = each.value.name
  fifo_topic        = false
  kms_master_key_id = aws_kms_key.messaging.arn
  tags              = var.tags
}

resource "aws_sqs_queue" "this" {
  for_each = var.consumers

  name                       = each.value.name
  visibility_timeout_seconds = each.value.visibility_timeout_seconds
  message_retention_seconds  = each.value.message_retention_seconds
  receive_wait_time_seconds  = each.value.receive_message_wait_time_seconds
  sqs_managed_sse_enabled    = true
  tags                       = var.tags
}

resource "aws_sqs_queue" "dead_letter" {
  for_each = local.redrive_consumers

  name                      = each.value.redrive.dead_letter_queue_name
  message_retention_seconds = each.value.redrive.dead_letter_message_retention_seconds
  sqs_managed_sse_enabled   = true
  tags                      = merge(var.tags, { purpose = "dead-letter" })
}

data "aws_iam_policy_document" "allow_sns" {
  for_each = var.consumers

  statement {
    sid    = "AllowSnsTopic"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["sns.${data.aws_partition.current.dns_suffix}"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.this[each.key].arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.this[each.value.destination].arn]
    }
  }
}

resource "aws_sqs_queue_policy" "allow_sns" {
  for_each = var.consumers

  queue_url = aws_sqs_queue.this[each.key].url
  policy    = data.aws_iam_policy_document.allow_sns[each.key].json
}

resource "aws_sns_topic_subscription" "this" {
  for_each = var.consumers

  topic_arn            = aws_sns_topic.this[each.value.destination].arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.this[each.key].arn
  raw_message_delivery = true
  filter_policy_scope  = each.value.routing_mode == "include" ? "MessageAttributes" : null
  filter_policy = each.value.routing_mode == "include" ? jsonencode({
    EventType = sort(tolist(each.value.event_types))
  }) : null

  depends_on = [aws_sqs_queue_policy.allow_sns]
}

resource "aws_sqs_queue_redrive_policy" "this" {
  for_each = local.redrive_consumers

  queue_url = aws_sqs_queue.this[each.key].url
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dead_letter[each.key].arn
    maxReceiveCount     = each.value.redrive.max_receive_count
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "this" {
  for_each = local.redrive_consumers

  queue_url = aws_sqs_queue.dead_letter[each.key].url
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.this[each.key].arn]
  })
}

resource "aws_iam_role_policy" "publishers" {
  for_each = local.sender_assignments

  name = "hexagon-sns-publish-${substr(sha1(each.key), 0, 12)}"
  role = each.value.role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PublishIntegrationEvents"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.this[each.value.destination_id].arn
      },
      {
        Sid    = "EncryptIntegrationEvents"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*"
        ]
        Resource = aws_kms_key.messaging.arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "receivers" {
  for_each = var.consumers

  name = "hexagon-sqs-consume-${substr(sha1(each.key), 0, 12)}"
  role = each.value.role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ConsumeIntegrationEvents"
      Effect = "Allow"
      Action = [
        "sqs:ChangeMessageVisibility",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
        "sqs:ReceiveMessage"
      ]
      Resource = aws_sqs_queue.this[each.key].arn
    }]
  })
}
