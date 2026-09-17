# This is the REAL project's backend config. Unlike bootstrap/, this one
# DOES use a remote backend - pointing at the S3 bucket + DynamoDB table
# that bootstrap/ just created.
#
# IMPORTANT: You must fill in bucket + dynamodb_table below with the
# exact output values from `terraform apply` in bootstrap/ before running
# `terraform init` here. Terraform backend blocks can't use variables,
# so these values have to be hardcoded.

terraform {
  backend "s3" {
    bucket       = "elearning-pipeline-tfstate-rinshan01"
    key          = "elearning-pipeline/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
    encrypt      = true
  }
}
