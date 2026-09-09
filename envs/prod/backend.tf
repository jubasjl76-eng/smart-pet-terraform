# Remote state, created by ../../bootstrap. `terraform init -backend=false`
# (what CI runs for validate) ignores this block.
terraform {
  backend "s3" {
    bucket         = "smart-pet-tfstate"
    key            = "prod/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "smart-pet-tflock"
    encrypt        = true
  }
}
