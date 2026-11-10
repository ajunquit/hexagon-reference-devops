mock_provider "aws" {}

run "protects_remote_state_with_encryption_versioning_and_locking" {
  command = plan

  variables {
    region         = "us-east-1"
    bucket_name    = "hexagon-example-terraform-state-0001"
    kms_alias_name = "hexagon-example-terraform-state"
    tags = {
      managed-by = "terraform"
    }
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.state.block_public_acls == true && aws_s3_bucket_public_access_block.state.block_public_policy == true
    error_message = "Terraform state must not be publicly accessible."
  }

  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "Terraform state objects must be versioned."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.state.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
    error_message = "Terraform state must use KMS encryption."
  }

  assert {
    condition     = aws_kms_key.state.enable_key_rotation == true && aws_kms_key.state.deletion_window_in_days == 30
    error_message = "The state KMS key must rotate and have a recovery window."
  }

  assert {
    condition     = output.backend_configuration.use_lockfile == true
    error_message = "The S3 backend must use native state lockfiles."
  }

  assert {
    condition     = output.state_keys.dev != output.state_keys.staging && output.state_keys.staging != output.state_keys.prod
    error_message = "Each environment must use an independent state key."
  }
}
