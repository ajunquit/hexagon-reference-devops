mock_provider "aws" {}

run "builds_topics_queues_filters_optional_redrive_and_least_privilege_roles" {
  command = plan

  override_resource {
    target          = aws_sqs_queue.this["worker"]
    override_during = plan
    values = {
      arn = "arn:aws:sqs:us-east-1:123456789012:hexagon-example-dev-worker"
    }
  }

  override_resource {
    target          = aws_sqs_queue.this["sales-worker"]
    override_during = plan
    values = {
      arn = "arn:aws:sqs:us-east-1:123456789012:hexagon-example-dev-sales-worker"
    }
  }

  override_resource {
    target          = aws_sqs_queue.dead_letter["sales-worker"]
    override_during = plan
    values = {
      arn = "arn:aws:sqs:us-east-1:123456789012:hexagon-example-dev-sales-worker-dlq"
    }
  }

  override_data {
    target = data.aws_iam_policy_document.messaging_key
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  override_resource {
    target          = aws_kms_key.messaging
    override_during = plan
    values = {
      arn    = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000001"
      key_id = "00000000-0000-0000-0000-000000000001"
    }
  }

  override_resource {
    target          = aws_sns_topic.this
    override_during = plan
    values = {
      arn = "arn:aws:sns:us-east-1:123456789012:hexagon-example-dev-integration-events"
    }
  }

  variables {
    region = "us-east-1"
    operations = {
      notification_targets = ["arn:aws:sns:us-east-1:123456789012:alerts"]
      operator_identities = {
        worker       = "hexagon-example-dev-worker-operations"
        sales-worker = "hexagon-example-dev-sales-worker-operations"
      }
      consumers = {
        worker       = { backlog_threshold = 1000, oldest_message_age_seconds = 300 }
        sales-worker = { backlog_threshold = 500, oldest_message_age_seconds = 300, dead_letter_threshold = 1, replay_enabled = true }
      }
    }
    kms_alias_name = "hexagon-example-dev-messaging"
    destinations = {
      integration-events = {
        name        = "hexagon-example-dev-integration-events"
        event_types = ["CustomerCreatedIntegrationEvent"]
        publishers = {
          hexagon-example-api          = "hexagon-example-dev-api"
          hexagon-example-worker       = "hexagon-example-dev-worker"
          hexagon-example-sales-worker = "hexagon-example-dev-sales-worker"
        }
      }
    }
    consumers = {
      worker = {
        name                              = "hexagon-example-dev-worker"
        destination                       = "integration-events"
        workload                          = "hexagon-example-worker"
        role_name                         = "hexagon-example-dev-worker"
        routing_mode                      = "all"
        event_types                       = []
        visibility_timeout_seconds        = 60
        message_retention_seconds         = 345600
        receive_message_wait_time_seconds = 20
        retry_visibility_timeout_seconds  = 30
        redrive = {
          enabled = false
        }
      }
      sales-worker = {
        name                              = "hexagon-example-dev-sales-worker"
        destination                       = "integration-events"
        workload                          = "hexagon-example-sales-worker"
        role_name                         = "hexagon-example-dev-sales-worker"
        routing_mode                      = "include"
        event_types                       = ["CustomerCreatedIntegrationEvent"]
        visibility_timeout_seconds        = 60
        message_retention_seconds         = 345600
        receive_message_wait_time_seconds = 20
        retry_visibility_timeout_seconds  = 30
        redrive = {
          enabled                               = true
          dead_letter_queue_name                = "hexagon-example-dev-sales-worker-dlq"
          max_receive_count                     = 5
          dead_letter_message_retention_seconds = 1209600
        }
      }
    }
  }

  assert {
    condition     = aws_kms_key.messaging.enable_key_rotation == true && aws_sns_topic.this["integration-events"].kms_master_key_id == aws_kms_key.messaging.arn
    error_message = "SNS topics must use the rotating customer-managed messaging key."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.messaging) == 5 && !contains(keys(aws_cloudwatch_metric_alarm.messaging), "worker/dead-letter")
    error_message = "Every source requires backlog/age alarms; only an enabled DLQ can have a dead-letter alarm."
  }

  assert {
    condition     = length(jsondecode(aws_iam_role_policy.operations["worker"].policy).Statement) == 1 && length(jsondecode(aws_iam_role_policy.operations["sales-worker"].policy).Statement) == 3
    error_message = "A consumer without a DLQ must have inspection permissions only."
  }

  assert {
    condition     = length(aws_sns_topic.this) == 1 && length(aws_sqs_queue.this) == 2
    error_message = "The logical SNS/SQS topology was not materialized."
  }

  assert {
    condition     = aws_sqs_queue.this["worker"].sqs_managed_sse_enabled == true && aws_sqs_queue.this["sales-worker"].sqs_managed_sse_enabled == true
    error_message = "Every source queue must use server-side encryption."
  }

  assert {
    condition     = length(aws_sqs_queue.dead_letter) == 1 && contains(keys(aws_sqs_queue.dead_letter), "sales-worker")
    error_message = "Only consumers that opt into redrive must get a dead-letter queue."
  }

  assert {
    condition     = length(aws_sqs_queue_redrive_policy.this) == 1 && length(aws_sqs_queue_redrive_allow_policy.this) == 1
    error_message = "Redrive must configure both source and dead-letter queue policies."
  }

  assert {
    condition     = aws_sns_topic_subscription.this["worker"].raw_message_delivery == true && aws_sns_topic_subscription.this["sales-worker"].raw_message_delivery == true
    error_message = "SNS must preserve the canonical body and attributes through raw delivery."
  }

  assert {
    condition     = aws_sns_topic_subscription.this["worker"].filter_policy == null
    error_message = "All routing must not add an SNS filter policy."
  }

  assert {
    condition     = jsondecode(aws_sns_topic_subscription.this["sales-worker"].filter_policy).EventType[0] == "CustomerCreatedIntegrationEvent"
    error_message = "Include routing must filter on the EventType message attribute."
  }

  assert {
    condition     = length(aws_iam_role_policy.publishers) == 3 && length(aws_iam_role_policy.receivers) == 2
    error_message = "Every workload must get only its publisher or consumer permissions."
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.publishers["integration-events/hexagon-example-api"].policy, "kms:GenerateDataKey")
    error_message = "Publishers must be able to use the SNS encryption key."
  }

  assert {
    condition     = output.workload_bindings["hexagon-example-sales-worker"]["Messaging__Aws__Sqs__Consumers__sales-worker__RetryVisibilityTimeoutSeconds"] == "30"
    error_message = "Consumer runtime settlement bindings were not generated."
  }

  assert {
    condition     = output.workload_bindings["hexagon-example-api"]["Messaging__Aws__Sns__Destinations__integration-events__Region"] == "us-east-1"
    error_message = "Publisher region binding was not generated."
  }
}
