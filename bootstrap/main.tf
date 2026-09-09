# Bootstrap — the S3 bucket + DynamoDB table that hold Terraform state for every
# other stack. Run once, with LOCAL state (there is no remote backend yet):
#
#   cd bootstrap
#   terraform init
#   terraform apply
#
# Then commit bootstrap/terraform.tfstate is NOT done — keep it local or move it
# into the bucket afterwards. The envs/ stacks reference this bucket in their
# backend.tf.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Local state on purpose: this stack creates the remote backend.
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "state_bucket" {
  type    = string
  default = "smart-pet-tfstate"
}

variable "lock_table" {
  type    = string
  default = "smart-pet-tflock"
}

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket

  # Terraform state is the crown jewels — do not let a bad `terraform destroy`
  # here wipe it.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "lock" {
  name         = var.lock_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

output "state_bucket" {
  value = aws_s3_bucket.state.id
}

output "lock_table" {
  value = aws_dynamodb_table.lock.name
}
