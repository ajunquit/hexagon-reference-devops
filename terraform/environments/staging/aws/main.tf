locals {
  common_tags = merge(var.tags, {
    environment = var.environment
    managed-by  = "terraform"
    product     = var.product
  })
}

module "aws_sns_sqs" {
  operations = var.operations
  source     = "../../../modules/messaging/aws-sns-sqs"

  region         = var.region
  kms_alias_name = var.kms_alias_name
  destinations   = var.destinations
  consumers      = var.consumers
  tags           = local.common_tags
}
