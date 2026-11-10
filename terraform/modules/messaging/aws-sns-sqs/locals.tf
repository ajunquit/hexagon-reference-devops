locals {
  redrive_consumers = {
    for consumer_id, consumer in var.consumers : consumer_id => consumer
    if consumer.redrive.enabled
  }

  all_queue_names = concat(
    [for consumer in values(var.consumers) : consumer.name],
    [for consumer in values(local.redrive_consumers) : consumer.redrive.dead_letter_queue_name]
  )

  sender_assignments = {
    for assignment in flatten([
      for destination_id, destination in var.destinations : [
        for workload, role_name in destination.publishers : {
          key            = "${destination_id}/${workload}"
          destination_id = destination_id
          workload       = workload
          role_name      = role_name
        }
      ]
    ]) : assignment.key => assignment
  }

  publisher_binding_fragments = flatten([
    for destination_id, destination in var.destinations : [
      for workload in keys(destination.publishers) : {
        workload = workload
        values = {
          "Messaging__Aws__Sns__Destinations__${destination_id}__TopicArn" = aws_sns_topic.this[destination_id].arn
          "Messaging__Aws__Sns__Destinations__${destination_id}__Region"   = var.region
        }
      }
    ]
  ])

  consumer_binding_fragments = [
    for consumer_id, consumer in var.consumers : {
      workload = consumer.workload
      values = {
        "Messaging__Aws__Sqs__Consumers__${consumer_id}__QueueUrl"                      = aws_sqs_queue.this[consumer_id].url
        "Messaging__Aws__Sqs__Consumers__${consumer_id}__Region"                        = var.region
        "Messaging__Aws__Sqs__Consumers__${consumer_id}__RetryVisibilityTimeoutSeconds" = tostring(consumer.retry_visibility_timeout_seconds)
      }
    }
  ]

  workload_names = toset(concat(
    [for binding in local.publisher_binding_fragments : binding.workload],
    [for binding in local.consumer_binding_fragments : binding.workload]
  ))

  workload_bindings = {
    for workload in local.workload_names : workload => merge(
      [for binding in concat(local.publisher_binding_fragments, local.consumer_binding_fragments) :
        binding.values if binding.workload == workload
      ]...
    )
  }
}
