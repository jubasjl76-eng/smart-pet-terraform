# alb — public Application Load Balancer. HTTPS when a cert ARN is given,
# otherwise HTTP-only (dev without a domain). Services attach their own target
# group + listener rule; the default action is a 404.

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
variable "public_subnet_ids" { type = list(string) }
variable "certificate_arn" {
  type    = string
  default = "" # "" = HTTP-only listener on :80
}
variable "enable_deletion_protection" {
  type    = bool
  default = false
}
variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  name  = "smart-pet-${var.environment}"
  https = var.certificate_arn != ""
}

resource "aws_security_group" "this" {
  name        = "${local.name}-alb"
  description = "Public ALB ${var.environment}"
  vpc_id      = var.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.this.id
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  count             = local.https ? 1 : 0
  security_group_id = aws_security_group.this.id
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_lb" "this" {
  name                       = local.name
  load_balancer_type         = "application"
  subnets                    = var.public_subnet_ids
  security_groups            = [aws_security_group.this.id]
  enable_deletion_protection = var.enable_deletion_protection
  tags                       = var.tags
}

# HTTP: redirect to HTTPS when we have a cert, else serve as the main listener.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = local.https ? [1] : []
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
  dynamic "default_action" {
    for_each = local.https ? [] : [1]
    content {
      type = "fixed-response"
      fixed_response {
        content_type = "text/plain"
        message_body = "no route"
        status_code  = "404"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count             = local.https ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "no route"
      status_code  = "404"
    }
  }
}

output "alb_arn" { value = aws_lb.this.arn }
output "dns_name" { value = aws_lb.this.dns_name }
output "zone_id" { value = aws_lb.this.zone_id }
output "security_group_id" { value = aws_security_group.this.id }

# The listener services should hang their rules off.
output "listener_arn" {
  value = local.https ? aws_lb_listener.https[0].arn : aws_lb_listener.http.arn
}
