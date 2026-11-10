output "kms_key" {
  description = "Customer-managed KMS key used by SNS topics."
  value = {
    alias = aws_kms_alias.messaging.name
    arn   = aws_kms_key.messaging.arn
  }
}

output "destinations" {
  description = "Physical SNS topic mapping by logical destination."
  value = {
    for destination_id, topic in aws_sns_topic.this : destination_id => {
      arn  = topic.arn
      name = topic.name
    }
  }
}

output "consumers" {
  description = "Physical SQS queue and optional dead-letter queue mapping by logical consumer."
  value = {
    for consumer_id, queue in aws_sqs_queue.this : consumer_id => {
      arn  = queue.arn
      name = queue.name
      url  = queue.url
      dead_letter_queue = var.consumers[consumer_id].redrive.enabled ? {
        arn  = aws_sqs_queue.dead_letter[consumer_id].arn
        name = aws_sqs_queue.dead_letter[consumer_id].name
        url  = aws_sqs_queue.dead_letter[consumer_id].url
      } : null
    }
  }
}

output "workload_bindings" {
  description = "Non-secret environment settings to inject into each publisher or consumer workload."
  value       = local.workload_bindings
}
