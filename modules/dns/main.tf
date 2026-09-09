# dns — a Route53 hosted zone (created or looked up) and a wildcard ACM cert
# with DNS validation. Disabled when zone_name is "" (dev without a domain):
# every output is empty and no resources are made.
#
# A/alias records for api → ALB and mqtt → NLB are created by the env (they need
# the load balancer DNS names), not here, to keep this module free of a cycle.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "zone_name" {
  description = "e.g. \"smartpet.example\". \"\" disables the module."
  type        = string
  default     = ""
}
variable "create_zone" {
  description = "true = create the hosted zone; false = look up an existing one."
  type        = bool
  default     = false
}
variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  enabled = var.zone_name != ""
}

resource "aws_route53_zone" "this" {
  count = local.enabled && var.create_zone ? 1 : 0
  name  = var.zone_name
  tags  = var.tags
}

data "aws_route53_zone" "this" {
  count = local.enabled && !var.create_zone ? 1 : 0
  name  = var.zone_name
}

locals {
  zone_id = local.enabled ? (var.create_zone ? aws_route53_zone.this[0].zone_id : data.aws_route53_zone.this[0].zone_id) : ""
}

resource "aws_acm_certificate" "this" {
  count                     = local.enabled ? 1 : 0
  domain_name               = var.zone_name
  subject_alternative_names = ["*.${var.zone_name}"]
  validation_method         = "DNS"
  tags                      = var.tags
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validation" {
  for_each = local.enabled ? {
    for o in aws_acm_certificate.this[0].domain_validation_options : o.domain_name => {
      name   = o.resource_record_name
      type   = o.resource_record_type
      record = o.resource_record_value
    }
  } : {}
  zone_id = local.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]
}

resource "aws_acm_certificate_validation" "this" {
  count                   = local.enabled ? 1 : 0
  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}

output "zone_id" {
  value = local.zone_id
}
output "certificate_arn" {
  value = local.enabled ? aws_acm_certificate_validation.this[0].certificate_arn : ""
}
