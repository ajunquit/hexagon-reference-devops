data "aws_caller_identity" "current" {}

locals {
  account = data.aws_caller_identity.current.account_id
  # The short prefix of the instance (ADR 0025): the same rule the lifecycle engine validates.
  name_prefix = "${var.name_prefix_base}-${substr(sha256("${var.product}/${var.environment}/${var.instance_id}"), 0, 6)}"
  identity    = "${var.product}-${var.environment}-${var.instance_id}"
  state_path  = "${var.product}/${var.environment}/${var.instance_id}"
  # Tags every resource of the instance carries through the default_tags of its roots.
  instance_tags = {
    "hexagon:product"     = var.product
    "hexagon:environment" = var.environment
    "hexagon:instance"    = var.instance_id
    "hexagon:name-prefix" = local.name_prefix
  }
  tags           = merge(var.tags, local.instance_tags, { managed-by = "terraform", "hexagon:scope" = "reservation", expires-at = tostring(var.expires_at) })
  github_subject = "${var.oidc_prefix}:environment:${var.environment}-${var.instance_id}"
  own_tag        = { "aws:ResourceTag/hexagon:instance" = var.instance_id }
  # Services whose resources are created with the instance tags and then managed through them.
  tagged_services = ["ec2", "rds", "ecs", "elasticloadbalancing", "logs", "secretsmanager", "sns", "sqs", "kms", "ecr", "cloudfront", "application-autoscaling", "cloudwatch"]
  tag_actions = [
    "ec2:CreateTags", "elasticloadbalancing:AddTags", "ecs:TagResource", "rds:AddTagsToResource", "logs:TagResource", "logs:TagLogGroup",
    "secretsmanager:TagResource", "sns:TagResource", "sqs:TagQueue", "kms:TagResource", "ecr:TagResource", "cloudfront:TagResource",
    "application-autoscaling:TagResource", "cloudwatch:TagResource",
  ]
  untag_actions = [
    "ec2:DeleteTags", "elasticloadbalancing:RemoveTags", "ecs:UntagResource", "rds:RemoveTagsFromResource", "logs:UntagResource", "logs:UntagLogGroup",
    "secretsmanager:UntagResource", "sns:UntagResource", "sqs:UntagQueue", "kms:UntagResource", "ecr:UntagResource", "cloudfront:UntagResource",
    "application-autoscaling:UntagResource", "cloudwatch:UntagResource", "iam:UntagRole", "s3:DeleteBucketTagging",
  ]
  tagging_requests = concat(local.tag_actions, ["iam:TagRole", "iam:CreateRole", "s3:PutBucketTagging"])
  own_roles        = "arn:aws:iam::${local.account}:role/${local.name_prefix}-*"
  web              = "arn:aws:s3:::${local.name_prefix}-web-${local.account}"

  policies = {
    # State, inventory, journal, lease and snapshots of this instance only, plus read-only observation.
    state = [
      { Sid = "OwnStateObjects", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:GetObjectVersion"], Resource = "arn:aws:s3:::${var.state_bucket}/${local.state_path}/*" },
      { Sid = "ListOwnStatePrefix", Effect = "Allow", Action = "s3:ListBucket", Resource = "arn:aws:s3:::${var.state_bucket}", Condition = { StringLike = { "s3:prefix" = "${local.state_path}/*" } } },
      { Sid = "StateEncryption", Effect = "Allow", Action = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"], Resource = var.state_kms_key_arn },
      {
        Sid = "ReadAndObserve", Effect = "Allow", Resource = "*", Action = [
          "sts:GetCallerIdentity", "ec2:Describe*", "rds:Describe*", "rds:ListTagsForResource", "ecs:Describe*", "ecs:List*",
          "elasticloadbalancing:Describe*", "cloudfront:Get*", "cloudfront:List*", "cloudfront:Describe*", "ecr:Describe*", "ecr:List*",
          "logs:Describe*", "logs:ListTagsForResource", "secretsmanager:ListSecrets", "sns:List*", "sns:GetTopicAttributes", "sqs:List*",
          "kms:DescribeKey", "kms:ListAliases", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus", "kms:ListResourceTags",
          "application-autoscaling:Describe*", "application-autoscaling:ListTagsForResource", "cloudwatch:Describe*", "cloudwatch:ListTagsForResource",
          "cloudcontrolapi:GetResource", "cloudcontrolapi:ListResources", "tag:GetResources", "iam:GetPolicy", "iam:GetPolicyVersion",
        ]
      },
      { Sid = "SimulateOwnIsolation", Effect = "Allow", Action = "iam:SimulatePrincipalPolicy", Resource = aws_iam_role.deployment.arn },
    ]
    # Creation only with the tags of this instance; a tag request never names or moves another instance.
    create = [
      {
        Sid       = "CreateTagged", Effect = "Allow", Resource = "*",
        Condition = { StringEquals = { "aws:RequestTag/hexagon:instance" = var.instance_id, "aws:RequestTag/hexagon:product" = var.product } },
        Action = [
          "ec2:CreateVpc", "ec2:CreateSubnet", "ec2:CreateInternetGateway", "ec2:CreateRouteTable", "ec2:CreateSecurityGroup",
          "rds:CreateDBInstance", "rds:CreateDBSubnetGroup", "ecs:CreateCluster", "ecs:RegisterTaskDefinition", "ecs:CreateService",
          "elasticloadbalancing:CreateLoadBalancer", "elasticloadbalancing:CreateTargetGroup", "elasticloadbalancing:CreateListener", "elasticloadbalancing:CreateRule",
          "cloudfront:CreateDistributionWithTags", "cloudfront:CreateVpcOrigin", "logs:CreateLogGroup", "secretsmanager:CreateSecret",
          "sns:CreateTopic", "sqs:CreateQueue", "kms:CreateKey", "ecr:CreateRepository", "application-autoscaling:RegisterScalableTarget", "cloudwatch:PutMetricAlarm",
        ]
      },
      {
        Sid       = "TagOwnResources", Effect = "Allow", Action = local.tag_actions, Resource = "*",
        Condition = { StringEquals = { "aws:RequestTag/hexagon:instance" = var.instance_id }, StringEqualsIfExists = local.own_tag }
      },
      {
        Sid       = "ServiceLinkedRoles", Effect = "Allow", Action = "iam:CreateServiceLinkedRole", Resource = "*",
        Condition = { StringEquals = { "iam:AWSServiceName" = ["ecs.amazonaws.com", "rds.amazonaws.com", "elasticloadbalancing.amazonaws.com", "ecs.application-autoscaling.amazonaws.com"] } }
      },
    ]
    # Every other action of those services, only on resources already tagged with this instance.
    manage = [
      { Sid = "ManageOwnTagged", Effect = "Allow", Action = [for service in local.tagged_services : "${service}:*"], Resource = "*", Condition = { StringEquals = local.own_tag } },
    ]
    # Resources whose actions do not carry tags: scoped by the short prefix instead.
    named = [
      {
        Sid = "OwnNamedResources", Effect = "Allow", Action = ["s3:*", "cloudfront:*Function*", "logs:*", "sns:*", "sqs:*", "secretsmanager:*", "ecr:*", "kms:*Alias", "rds:*"],
        Resource = [
          local.web, "${local.web}/*", "arn:aws:cloudfront::${local.account}:function/${local.name_prefix}-*",
          "arn:aws:logs:${var.region}:${local.account}:log-group:/hexagon/${local.name_prefix}", "arn:aws:logs:${var.region}:${local.account}:log-group:/hexagon/${local.name_prefix}:*",
          "arn:aws:sns:${var.region}:${local.account}:${local.name_prefix}-*", "arn:aws:sqs:${var.region}:${local.account}:${local.name_prefix}-*",
          "arn:aws:secretsmanager:${var.region}:${local.account}:secret:${local.name_prefix}/*", "arn:aws:ecr:${var.region}:${local.account}:repository/${local.name_prefix}/*",
          "arn:aws:kms:${var.region}:${local.account}:alias/${local.name_prefix}-*",
          "arn:aws:rds:${var.region}:${local.account}:db:${local.name_prefix}-*", "arn:aws:rds:${var.region}:${local.account}:subgrp:${local.name_prefix}-*",
        ]
      },
      { Sid = "OriginAccessControls", Effect = "Allow", Resource = "*", Action = ["cloudfront:CreateOriginAccessControl", "cloudfront:UpdateOriginAccessControl", "cloudfront:DeleteOriginAccessControl", "cloudfront:GetOriginAccessControl",
      "cloudfront:CreateResponseHeadersPolicy", "cloudfront:UpdateResponseHeadersPolicy", "cloudfront:DeleteResponseHeadersPolicy", "cloudfront:GetResponseHeadersPolicy"] },
      { Sid = "RegistryLogin", Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      # RDS creates the managed master secret on behalf of the caller.
      { Sid = "DatabaseManagedSecret", Effect = "Allow", Action = ["secretsmanager:CreateSecret", "secretsmanager:TagResource", "secretsmanager:DeleteSecret", "secretsmanager:DescribeSecret"], Resource = "arn:aws:secretsmanager:${var.region}:${local.account}:secret:rds!*" },
      # Roles of the instance: its prefix and always the workload boundary, so they never exceed it.
      {
        Sid       = "CreateBoundedRoles", Effect = "Allow", Action = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"], Resource = local.own_roles,
        Condition = { StringEquals = { "iam:PermissionsBoundary" = var.workload_boundary_arn, "aws:RequestTag/hexagon:instance" = var.instance_id, "aws:RequestTag/hexagon:name-prefix" = local.name_prefix } }
      },
      {
        Sid = "ManageOwnRoles", Effect = "Allow", Resource = local.own_roles, Action = [
          "iam:GetRole", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole", "iam:GetRolePolicy",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:UpdateRole", "iam:UpdateRoleDescription", "iam:UpdateAssumeRolePolicy",
          "iam:TagRole", "iam:ListRoleTags", "iam:DeleteRole",
        ]
      },
      { Sid = "AttachExecutionPolicyOnly", Effect = "Allow", Action = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"], Resource = local.own_roles, Condition = { ArnEquals = { "iam:PolicyARN" = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" } } },
      { Sid = "PassOwnRolesToTasks", Effect = "Allow", Action = "iam:PassRole", Resource = local.own_roles, Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } } },
    ]
    # Explicit denials that no allow can override.
    guardrails = [
      { Sid = "NoStaticCredentialsOrFederation", Effect = "Deny", Resource = "*", Action = ["iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile", "iam:*OpenIDConnectProvider*", "iam:*SAMLProvider*", "organizations:*", "account:*"] },
      { Sid = "BoundaryIsPermanent", Effect = "Deny", Resource = "*", Action = ["iam:DeleteRolePermissionsBoundary", "iam:CreatePolicyVersion", "iam:DeletePolicy", "iam:SetDefaultPolicyVersion"] },
      # The workload boundary trusts the tags of each role: no request may write another instance into them.
      { Sid = "NoForeignInstanceTag", Effect = "Deny", Resource = "*", Action = local.tagging_requests, Condition = { StringNotEqualsIfExists = { "aws:RequestTag/hexagon:instance" = var.instance_id } } },
      { Sid = "NoForeignNamePrefixTag", Effect = "Deny", Resource = "*", Action = local.tagging_requests, Condition = { StringNotEqualsIfExists = { "aws:RequestTag/hexagon:name-prefix" = local.name_prefix } } },
      { Sid = "InstanceTagsArePermanent", Effect = "Deny", Resource = "*", Action = local.untag_actions, Condition = { "ForAnyValue:StringLike" = { "aws:TagKeys" = "hexagon:*" } } },
      { Sid = "NoObjectsOutsideOwnPrefixes", Effect = "Deny", Action = ["s3:PutObject", "s3:DeleteObject", "s3:GetObject"], NotResource = ["arn:aws:s3:::${var.state_bucket}/${local.state_path}/*", "${local.web}/*"] },
    ]
  }
}

# The deployment identity of the reservation: GitHub Actions of the DevOps repository, only from the
# GitHub Environment <environment>-<instance>. It is not named with the short prefix, so the instance
# can never change it (ADR 0025).
resource "aws_iam_role" "deployment" {
  name                 = "${local.identity}-deploy"
  max_session_duration = 3600
  tags                 = local.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow", Action = "sts:AssumeRoleWithWebIdentity", Principal = { Federated = var.github_oidc_provider_arn }
      Condition = { StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com", "token.actions.githubusercontent.com:sub" = local.github_subject } }
    }]
  })
  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = length("${local.identity}-deploy") <= 64
      error_message = "The deployment role name exceeds 64 characters."
    }
  }
}

resource "aws_iam_policy" "deployment" {
  for_each    = local.policies
  name        = "${local.identity}-${each.key}"
  description = "Deployment permissions (${each.key}) of the reservation ${local.identity} (ADR 0025)."
  policy      = jsonencode({ Version = "2012-10-17", Statement = each.value })
  tags        = local.tags
}

resource "aws_iam_role_policy_attachment" "deployment" {
  for_each   = aws_iam_policy.deployment
  role       = aws_iam_role.deployment.name
  policy_arn = each.value.arn
}
