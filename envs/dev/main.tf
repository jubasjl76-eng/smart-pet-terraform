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

  tags = local.tags
}

# Backend service → Postgres. A standalone rule (not passed into module.database)
# so there is no module-level cycle: database → backend SG → backend → database.
resource "aws_vpc_security_group_ingress_rule" "db_from_backend" {
  security_group_id            = module.database.security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.backend.security_group_id
}

module "alb" {
  source            = "../../modules/alb"
  environment       = local.environment
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  certificate_arn   = "" # dev: HTTP on :80 (no domain yet); dns slice adds ACM
  tags              = local.tags
}

module "ecs_cluster" {
  source      = "../../modules/ecs-cluster"
  environment = local.environment
  secret_arns = [module.secrets.app_secret_arn, module.database.master_user_secret_arn]
  tags        = local.tags
}

module "backend" {
  source             = "../../modules/ecs-service"
  name               = "backend"
  environment        = local.environment
  region             = var.region
  cluster_arn        = module.ecs_cluster.cluster_arn
  cluster_name       = module.ecs_cluster.cluster_name
  execution_role_arn = module.ecs_cluster.execution_role_arn

  image          = "${module.ecr.repository_urls["backend"]}:latest"
  container_port = 3000
  cpu            = 512
  memory         = 1024
  desired_count  = 1
  min_count      = 1
  max_count      = 3

  vpc_id                = module.network.vpc_id
  private_subnet_ids    = module.network.private_subnet_ids
  alb_security_group_id = module.alb.security_group_id
  alb_listener_arn      = module.alb.listener_arn
  listener_priority     = 100
  health_check_path     = "/health"

  environment_vars = {
    NODE_ENV    = "production"
    PORT        = "3000"
    PG_HOST     = module.database.address
    PG_PORT     = "5432"
    PG_DATABASE = module.database.db_name
  }
  secret_refs = {
    JWT_SECRET  = "${module.secrets.app_secret_arn}:JWT_SECRET::"
    PG_USER     = "${module.database.master_user_secret_arn}:username::"
    PG_PASSWORD = "${module.database.master_user_secret_arn}:password::"
  }

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

output "alb_dns_name" {
  value = module.alb.dns_name
}

output "backend_log_group" {
  value = module.backend.log_group
}
