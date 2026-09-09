# cache — ElastiCache Redis in the private subnets (hardening Phase 12, A11).
#
# Dormant until Phase 20 wires it (rate-limit store, cross-instance SSE fan-out,
# the engine-sweep leader lock, the idempotency store). `enabled = false` (dev,
# local) creates nothing; services fall back to in-memory.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "environment" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }

variable "enabled" {
  description = "false → no Redis (dev/local use an in-memory fallback)."
  type        = bool
  default     = false
}

variable "allowed_security_group_ids" {
  description = "SGs allowed to reach 6379 (the service SGs)."
  type        = list(string)
  default     = []
}

variable "node_type" {
  type    = string
  default = "cache.t4g.micro"
}

variable "replicas" {
  description = "Read replicas. >0 turns on Multi-AZ automatic failover."
  type        = number
  default     = 0
}

variable "engine_version" {
  type    = string
  default = "7.1"
}

variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  name  = "smart-pet-${var.environment}"
  count = var.enabled ? 1 : 0
}

resource "aws_elasticache_subnet_group" "this" {
  count      = local.count
  name       = "${local.name}-redis"
  subnet_ids = var.private_subnet_ids
  tags       = var.tags
}

resource "aws_security_group" "this" {
  count       = local.count
  name        = "${local.name}-redis"
  description = "Redis ${var.environment}"
  vpc_id      = var.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "from_sg" {
  for_each                     = var.enabled ? toset(var.allowed_security_group_ids) : toset([])
  security_group_id            = aws_security_group.this[0].id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  referenced_security_group_id = each.value
}

resource "aws_vpc_security_group_egress_rule" "all" {
  count             = local.count
  security_group_id = aws_security_group.this[0].id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_elasticache_replication_group" "this" {
  count                      = local.count
  replication_group_id       = "${local.name}-redis"
  description                = "Smart Pet ${var.environment} Redis"
  engine                     = "redis"
  engine_version             = var.engine_version
  node_type                  = var.node_type
  port                       = 6379
  num_cache_clusters         = 1 + var.replicas
  automatic_failover_enabled = var.replicas > 0
  multi_az_enabled           = var.replicas > 0
  subnet_group_name          = aws_elasticache_subnet_group.this[0].name
  security_group_ids         = [aws_security_group.this[0].id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  apply_immediately          = true
  tags                       = var.tags
}

output "enabled" {
  value = var.enabled
}

output "security_group_id" {
  value = var.enabled ? aws_security_group.this[0].id : ""
}

output "primary_endpoint" {
  value = var.enabled ? aws_elasticache_replication_group.this[0].primary_endpoint_address : ""
}

# rediss:// (TLS) — transit encryption is on. Empty when disabled so callers can
# treat "" as "use the in-memory fallback".
output "redis_url" {
  value = var.enabled ? "rediss://${aws_elasticache_replication_group.this[0].primary_endpoint_address}:6379" : ""
}
