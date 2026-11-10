output "backend_configuration" {
  description = "Non-secret S3 backend settings. Authentication is supplied externally."
  value = {
    bucket       = aws_s3_bucket.state.id
    region       = var.region
    encrypt      = true
    kms_key_id   = aws_kms_key.state.arn
    use_lockfile = true
  }
}

output "state_keys" {
  description = "Independent state keys for bootstrap and each product environment."
  value = {
    bootstrap = "bootstrap.tfstate"
    dev       = "dev/terraform.tfstate"
    staging   = "staging/terraform.tfstate"
    prod      = "prod/terraform.tfstate"
  }
}
