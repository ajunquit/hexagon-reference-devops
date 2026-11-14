mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/hexagon-template-dev-run-12345-1-deploy" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/hexagon-template-dev-run-12345-1-part" }
  }
}

variables {
  region                   = "us-east-1"
  product                  = "hexagon-template"
  environment              = "dev"
  instance_id              = "run-12345-1"
  name_prefix_base         = "tpl-dev"
  oidc_prefix              = "repo:example-owner/hexagon-template-devops"
  github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  workload_boundary_arn    = "arn:aws:iam::123456789012:policy/hexagon-workload-boundary"
  state_bucket             = "hexagon-template-tfstate-123456789012"
  state_kms_key_arn        = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  expires_at               = 1893456000
}

run "the_reservation_federates_one_environment_with_a_short_prefix" {
  assert {
    condition     = output.name_prefix == "tpl-dev-e1c8fa" && output.github_environment == "dev-run-12345-1" && output.state_prefix == "hexagon-template/dev/run-12345-1"
    error_message = "The short prefix must follow the lifecycle engine rule (examples/environment-inventory-aws.json)."
  }
  assert {
    condition = (jsondecode(aws_iam_role.deployment.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] ==
      "repo:example-owner/hexagon-template-devops:environment:dev-run-12345-1" &&
    jsondecode(aws_iam_role.deployment.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com")
    error_message = "Only the exact GitHub Environment of the reservation may assume the role."
  }
  assert {
    condition     = !startswith(aws_iam_role.deployment.name, output.name_prefix) && length(aws_iam_role_policy_attachment.deployment) == 5
    error_message = "The deployment role lies outside the prefix it manages and carries every policy."
  }
  assert {
    condition     = aws_iam_role.deployment.tags["hexagon:instance"] == "run-12345-1" && aws_iam_role.deployment.tags["expires-at"] == "1893456000"
    error_message = "The reservation must carry its instance and expiry."
  }
}

run "state_and_creation_stay_inside_the_instance" {
  assert {
    condition = (jsondecode(aws_iam_policy.deployment["state"].policy).Statement[0].Resource == "arn:aws:s3:::hexagon-template-tfstate-123456789012/hexagon-template/dev/run-12345-1/*" &&
    jsondecode(aws_iam_policy.deployment["state"].policy).Statement[1].Condition.StringLike["s3:prefix"] == "hexagon-template/dev/run-12345-1/*")
    error_message = "State objects are limited to the prefix of the instance."
  }
  assert {
    condition = alltrue([for statement in jsondecode(aws_iam_policy.deployment["create"].policy).Statement :
    statement.Sid == "ServiceLinkedRoles" || statement.Condition.StringEquals["aws:RequestTag/hexagon:instance"] == "run-12345-1"])
    error_message = "Every creation or tag request must carry the instance tag."
  }
  assert {
    condition     = jsondecode(aws_iam_policy.deployment["manage"].policy).Statement[0].Condition.StringEquals["aws:ResourceTag/hexagon:instance"] == "run-12345-1"
    error_message = "Existing resources are managed only when tagged with this instance."
  }
}

run "roles_are_bounded_and_guardrails_deny_escalation" {
  assert {
    condition = (one([for statement in jsondecode(aws_iam_policy.deployment["named"].policy).Statement : statement if statement.Sid == "CreateBoundedRoles"]).Condition.StringEquals["iam:PermissionsBoundary"] ==
    "arn:aws:iam::123456789012:policy/hexagon-workload-boundary")
    error_message = "Every role of the instance must carry the workload boundary."
  }
  assert {
    condition     = one([for statement in jsondecode(aws_iam_policy.deployment["named"].policy).Statement : statement if statement.Sid == "PassOwnRolesToTasks"]).Resource == "arn:aws:iam::123456789012:role/tpl-dev-e1c8fa-*"
    error_message = "Only roles of the instance may be passed, and only to ECS tasks."
  }
  assert {
    condition = alltrue([for statement in jsondecode(aws_iam_policy.deployment["guardrails"].policy).Statement : statement.Effect == "Deny"]) && contains(
    [for statement in jsondecode(aws_iam_policy.deployment["guardrails"].policy).Statement : statement.Sid], "NoForeignInstanceTag")
    error_message = "Guardrails must deny static credentials, boundary removal and foreign instance tags."
  }
}

run "persistent_and_production_environments_are_not_reserved_here" {
  command = plan
  variables { environment = "prod" }
  expect_failures = [var.environment]
}

run "the_prefix_base_must_leave_room_for_the_instance_hash" {
  command = plan
  variables { name_prefix_base = "a-very-long-base" }
  expect_failures = [var.name_prefix_base]
}

run "only_the_product_devops_repository_may_deploy" {
  command = plan
  variables { oidc_prefix = "repo:example-owner/another-repository" }
  expect_failures = [var.oidc_prefix]
}
