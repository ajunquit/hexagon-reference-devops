data "aws_caller_identity" "current" {}

locals {
  account = data.aws_caller_identity.current.account_id
  tags    = merge(var.tags, { managed-by = "terraform", "hexagon:scope" = "account-bootstrap" })
  # IAM policy variables, resolved at request time from the tags of the calling role (ADR 0025).
  instance = "$${aws:PrincipalTag/hexagon:instance}"
  prefix   = "$${aws:PrincipalTag/hexagon:name-prefix}"
  # The ceiling of every role an environment creates (task, execution and maintenance roles):
  # whatever their own policies say, they reach only data-plane actions on resources of their own
  # instance, so a deployment role cannot escalate by creating roles.
  workload_boundary = [
    {
      Sid = "OwnInstanceData", Effect = "Allow", Resource = "*", Condition = { StringEquals = { "aws:ResourceTag/hexagon:instance" = local.instance } },
      Action = [
        "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes", "sqs:GetQueueUrl", "sqs:SendMessage",
        "sns:Publish", "secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue", "secretsmanager:DescribeSecret",
        "kms:Decrypt", "kms:GenerateDataKey", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability",
      ]
    },
    {
      Sid       = "OwnDatabaseAdministratorSecret", Effect = "Allow", Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
      Resource  = "arn:aws:secretsmanager:*:${local.account}:secret:rds!*",
      Condition = { StringLike = { "aws:ResourceTag/aws:rds:primaryDBInstanceArn" = "arn:aws:rds:*:${local.account}:db:${local.prefix}-postgres" } }
    },
    { Sid = "OwnLogs", Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "arn:aws:logs:*:${local.account}:log-group:/hexagon/${local.prefix}:*" },
    { Sid = "RegistryLogin", Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
  ]
}

# GitHub Actions federation for the whole account. Each environment role trusts it only for the
# exact repository and GitHub Environment of its reservation.
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.github_oidc_provider_arn == null ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  tags           = local.tags
  lifecycle { prevent_destroy = true }
}

resource "aws_iam_policy" "workload_boundary" {
  name        = var.workload_boundary_name
  description = "Permissions boundary of every role created by a Hexagon environment (ADR 0025)."
  policy      = jsonencode({ Version = "2012-10-17", Statement = local.workload_boundary })
  tags        = local.tags
  lifecycle { prevent_destroy = true }
}
