locals {
  environment = "dev"
  tags = {
    Project     = "smart-pet"
    Environment = local.environment
    ManagedBy   = "terraform"
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = local.tags
  }
}

variable "region" {
  type    = string
  default = "eu-west-1"
}

module "network" {
  source      = "../../modules/network"
  project     = "smart-pet"
  environment = local.environment
  region      = var.region
  vpc_cidr    = "10.10.0.0/16"
  single_nat  = true # dev: one NAT for the VPC
  tags        = local.tags
}

module "secrets" {
  source      = "../../modules/secrets"
  environment = local.environment
  tags        = local.tags
}

module "ecr" {
  source = "../../modules/ecr"
  tags   = local.tags
}

module "database" {
  source             = "../../modules/database"
  environment        = local.environment
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids

  instance_class      = "db.t4g.micro"
  multi_az            = false
  deletion_protection = false
  skip_final_snapshot = true
  # dev: reachable from anything in the VPC until the backend SG exists (ecs slice)
  allowed_cidr_blocks = [module.network.vpc_cidr]

  tags = local.tags
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "db_address" {
  value = module.database.address
}

output "db_master_secret_arn" {
  value = module.database.master_user_secret_arn
}

output "app_secret_arn" {
  value = module.secrets.app_secret_arn
}

output "private_subnet_ids" {
  value = module.network.private_subnet_ids
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}
