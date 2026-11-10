output "aws_sns_sqs" {
  description = "AWS SNS/SQS physical mappings and runtime bindings."
  value = {
    kms_key           = module.aws_sns_sqs.kms_key
    destinations      = module.aws_sns_sqs.destinations
    consumers         = module.aws_sns_sqs.consumers
    workload_bindings = module.aws_sns_sqs.workload_bindings
  }
}
