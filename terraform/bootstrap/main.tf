# --- S3 bucket to store Terraform's state file ---
# Terraform state is basically a JSON file that records every resource
# Terraform has created and its current settings. If this lived only on
# your laptop, you couldn't safely re-run Terraform from another machine
# and you'd risk losing it. Storing it in S3 makes it durable and shared.
resource "aws_s3_bucket" "tf_state" {
  bucket = "${var.project_name}-tfstate-${var.unique_suffix}"

  tags = {
    Project = var.project_name
    Purpose = "terraform-state"
  }
}

# Versioning means every time the state file changes, S3 keeps the old
# version too. If Terraform state ever gets corrupted, you can roll back.
resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt the state file at rest - it can contain sensitive values
# (like ARNs, resource IDs, sometimes secrets) so this isn't optional.
resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block all public access to this bucket - state files should never be
# publicly readable under any circumstance.
resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- DynamoDB table for state locking ---
# When you run `terraform apply`, Terraform writes a "lock" row to this
# table before it starts, and removes it when done. If a second
# `terraform apply` tries to run at the same time, it sees the lock and
# refuses to run - preventing two applies from corrupting the state
# file by writing to it simultaneously.
resource "aws_dynamodb_table" "tf_lock" {
  name         = "${var.project_name}-tf-lock"
  billing_mode = "PAY_PER_REQUEST" # no fixed cost, scales to zero when idle
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Project = var.project_name
    Purpose = "terraform-state-lock"
  }
}
