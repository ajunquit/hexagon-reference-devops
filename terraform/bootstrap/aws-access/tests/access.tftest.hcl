mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
  }
}

variables {
  region = "us-east-1"
}

run "creates_the_account_federation_and_the_workload_boundary" {
  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 1 && aws_iam_openid_connect_provider.github[0].client_id_list == toset(["sts.amazonaws.com"])
    error_message = "The account federates GitHub Actions for STS only."
  }
  assert {
    condition = (jsondecode(aws_iam_policy.workload_boundary.policy).Statement[0].Condition.StringEquals["aws:ResourceTag/hexagon:instance"] == "$${aws:PrincipalTag/hexagon:instance}" &&
    !contains(jsondecode(aws_iam_policy.workload_boundary.policy).Statement[0].Action, "iam:PassRole"))
    error_message = "Workload roles reach only data of their own instance and never IAM."
  }
  assert {
    condition     = alltrue([for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement : !anytrue([for action in flatten([statement.Action]) : can(regex("^(iam|sts|organizations):", action))])])
    error_message = "The boundary never grants identity or account administration."
  }
}
