locals {
  environment = "staging"
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

variable "zone_name" {
  description = "Route53 zone for api./mqtt. + regional ACM. \"\" = HTTP/plain."
  type        = string
  default     = ""
}

variable "create_zone" {
  type    = bool
  default = false
}

variable "alarm_email" {
  type    = string
  default = ""
}

variable "broker_image" {
  description = "staging broker image with an auth backend."
  type        = string
  default     = "eclipse-mosquitto:2"
}

# staging = prod topology, minimal sizing. Single NAT, single-AZ DB, one broker,
# one task per service, Redis without a replica.

module "network" {
  source      = "../../modules/network"
  project     = "smart-pet"
  environment = local.environment
  region      = var.region
  vpc_cidr    = "10.30.0.0/16"
  single_nat  = true
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

  instance_class          = "db.t4g.micro"
  allocated_storage       = 20
  max_allocated_storage   = 100
  multi_az                = false
  deletion_protection     = false
  skip_final_snapshot     = true
  backup_retention_period = 7
  performance_insights    = false

  tags = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "db_from_backend" {
  security_group_id            = module.database.security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.backend.security_group_id
}

module "cache" {
  source                     = "../../modules/cache"
  environment                = local.environment
  vpc_id                     = module.network.vpc_id
  private_subnet_ids         = module.network.private_subnet_ids
  enabled                    = true
  replicas                   = 0
  allowed_security_group_ids = [module.backend.security_group_id, module.sensors.security_group_id]
  tags                       = local.tags
}

module "dns" {
  source      = "../../modules/dns"
  zone_name   = var.zone_name
  create_zone = var.create_zone
  tags        = local.tags
}

module "alb" {
  source                     = "../../modules/alb"
  environment                = local.environment
  vpc_id                     = module.network.vpc_id
  public_subnet_ids          = module.network.public_subnet_ids
  certificate_arn            = module.dns.certificate_arn
  enable_deletion_protection = false
  tags                       = local.tags
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
  max_count      = 2

  vpc_id                = module.network.vpc_id
  private_subnet_ids    = module.network.private_subnet_ids
  alb_security_group_id = module.alb.security_group_id
  alb_listener_arn      = module.alb.listener_arn
  listener_priority     = 100
  health_check_path     = "/ready"

  environment_vars = {
    NODE_ENV    = "staging"
    PORT        = "3000"
    PG_HOST     = module.database.address
    PG_PORT     = "5432"
    PG_DATABASE = module.database.db_name
    REDIS_URL   = module.cache.redis_url
  }
  secret_refs = {
    JWT_SECRET  = "${module.secrets.app_secret_arn}:JWT_SECRET::"
    PG_USER     = "${module.database.master_user_secret_arn}:username::"
    PG_PASSWORD = "${module.database.master_user_secret_arn}:password::"
  }

  tags = local.tags
}

module "mqtt_broker" {
  source              = "../../modules/mqtt-broker"
  environment         = local.environment
  region              = var.region
  vpc_id              = module.network.vpc_id
  public_subnet_ids   = module.network.public_subnet_ids
  private_subnet_ids  = module.network.private_subnet_ids
  cluster_arn         = module.ecs_cluster.cluster_arn
  cluster_name        = module.ecs_cluster.cluster_name
  execution_role_arn  = module.ecs_cluster.execution_role_arn
  certificate_arn     = module.dns.certificate_arn
  image               = var.broker_image
  desired_count       = 1
  dev_allow_anonymous = false
  tags                = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "mqtt_from_backend" {
  security_group_id            = module.mqtt_broker.security_group_id
  from_port                    = 1883
  to_port                      = 1883
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.backend.security_group_id
}

module "sensors" {
  source             = "../../modules/ecs-service"
  name               = "sensors"
  environment        = local.environment
  region             = var.region
  cluster_arn        = module.ecs_cluster.cluster_arn
  cluster_name       = module.ecs_cluster.cluster_name
  execution_role_arn = module.ecs_cluster.execution_role_arn

  image          = "${module.ecr.repository_urls["sensors"]}:latest"
  container_port = 3005
  cpu            = 256
  memory         = 512
  desired_count  = 1
  min_count      = 1
  max_count      = 2

  vpc_id                = module.network.vpc_id
  private_subnet_ids    = module.network.private_subnet_ids
  alb_security_group_id = module.alb.security_group_id
  alb_listener_arn      = module.alb.listener_arn
  listener_priority     = 50
  path_patterns         = ["/api/sensors*", "/api/alerts*"]
  health_check_path     = "/ready"

  environment_vars = {
    NODE_ENV           = "staging"
    PORT               = "3005"
    MQTT_HOST          = module.mqtt_broker.nlb_dns_name
    MQTT_PORT          = "1883"
    CLOUD_BACKEND_URL  = var.zone_name == "" ? "http://${module.alb.dns_name}/api" : "https://api.${var.zone_name}/api"
    OFFLINE_QUEUE_FILE = "/tmp/offline-queue.json"
  }
  secret_refs = {
    API_KEY = "${module.secrets.app_secret_arn}:SENSORS_API_KEY::"
  }

  tags = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "mqtt_from_sensors" {
  security_group_id            = module.mqtt_broker.security_group_id
  from_port                    = 1883
  to_port                      = 1883
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.sensors.security_group_id
}

module "cdn_assets" {
  source      = "../../modules/cdn"
  name        = "assets"
  environment = local.environment
  spa         = false
  price_class = "PriceClass_100"
  tags        = local.tags
}

module "cdn_dashboard" {
  source      = "../../modules/cdn"
  name        = "dashboard"
  environment = local.environment
  spa         = true
  price_class = "PriceClass_100"
  tags        = local.tags
}

module "oidc" {
  source              = "../../modules/oidc"
  environment         = local.environment
  create_provider     = false # dev's stack owns the account-global provider
  ecr_repository_arns = module.ecr.repository_arns
  deploy_repos = {
    backend = { repo = "smart-pet-backend", ref = "ref:refs/tags/v*-rc.*" }
    sensors = { repo = "pet-iot-sensors-service", ref = "ref:refs/tags/v*-rc.*" }
  }
  tags = local.tags
}

module "observability" {
  source                  = "../../modules/observability"
  environment             = local.environment
  region                  = var.region
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.backend.target_group_arn_suffix
  cluster_name            = module.ecs_cluster.cluster_name
  db_identifier           = module.database.identifier
  backend_desired_count   = 1
  alarm_email             = var.alarm_email
  tags                    = local.tags
}

resource "aws_route53_record" "api" {
  count   = var.zone_name == "" ? 0 : 1
  zone_id = module.dns.zone_id
  name    = "api.${var.zone_name}"
  type    = "A"
  alias {
    name                   = module.alb.dns_name
    zone_id                = module.alb.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "mqtt" {
  count   = var.zone_name == "" ? 0 : 1
  zone_id = module.dns.zone_id
  name    = "mqtt.${var.zone_name}"
  type    = "A"
  alias {
    name                   = module.mqtt_broker.nlb_dns_name
    zone_id                = module.mqtt_broker.nlb_zone_id
    evaluate_target_health = true
  }
}

output "alb_dns_name" { value = module.alb.dns_name }
output "mqtt_endpoint" { value = module.mqtt_broker.endpoint_plain }
output "ecr_repository_urls" { value = module.ecr.repository_urls }
output "db_address" { value = module.database.address }
output "app_secret_arn" { value = module.secrets.app_secret_arn }
output "redis_url" { value = module.cache.redis_url }
output "cdn_dashboard_domain" { value = module.cdn_dashboard.domain_name }
output "gha_deploy_role_arns" { value = module.oidc.deploy_role_arns }
output "gha_terraform_role_arn" { value = module.oidc.terraform_role_arn }
