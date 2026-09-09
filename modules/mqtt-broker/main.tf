# mqtt-broker — Mosquitto on Fargate behind a Network Load Balancer. EFS holds
# the config + retained-message store so a task replacement keeps state.
# TLS :8883 when a cert is given; plain :1883 always.
#
# dev runs `eclipse-mosquitto:2` with allow_anonymous. prod must swap `image`
# for one with an auth backend (dynamic-security or a plugin the backend feeds).

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

locals {
  name = "smart-pet-${var.environment}-mqtt"
  tls  = var.certificate_arn != ""
  conf = <<-EOT
    listener 1883
    ${var.dev_allow_anonymous ? "allow_anonymous true" : "allow_anonymous false"}
    persistence true
    persistence_location /mosquitto/data/
    autosave_interval 60
    max_inflight_messages 200
    log_dest stdout
    log_type warning
    log_type notice
  EOT
}

# ── EFS for config + data ──────────────────────────────────────────────────
resource "aws_security_group" "efs" {
  name        = "${local.name}-efs"
  description = "EFS for ${local.name}"
  vpc_id      = var.vpc_id
  tags        = var.tags
}

resource "aws_security_group" "broker" {
  name        = "${local.name}-svc"
  description = "${local.name} tasks"
  vpc_id      = var.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "efs_from_broker" {
  security_group_id            = aws_security_group.efs.id
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.broker.id
}

resource "aws_vpc_security_group_egress_rule" "broker_all" {
  security_group_id = aws_security_group.broker.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# NLB has no SG; tasks must accept the health check + client traffic. NLB
# preserves source IP, so allow the client CIDRs directly on the task SG.
resource "aws_vpc_security_group_ingress_rule" "mqtt" {
  for_each          = toset(var.allowed_cidrs)
  security_group_id = aws_security_group.broker.id
  from_port         = 1883
  to_port           = 1883
  ip_protocol       = "tcp"
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "mqtt_vpc_healthcheck" {
  security_group_id = aws_security_group.broker.id
  from_port         = 1883
  to_port           = 1883
  ip_protocol       = "tcp"
  cidr_ipv4         = "10.0.0.0/8"
}

resource "aws_efs_file_system" "this" {
  creation_token = local.name
  encrypted      = true
  tags           = var.tags
}

resource "aws_efs_mount_target" "this" {
  for_each        = toset(var.private_subnet_ids)
  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_access_point" "this" {
  file_system_id = aws_efs_file_system.this.id
  posix_user {
    uid = 1883
    gid = 1883
  }
  root_directory {
    path = "/mosquitto"
    creation_info {
      owner_uid   = 1883
      owner_gid   = 1883
      permissions = "0755"
    }
  }
  tags = var.tags
}

# ── Network Load Balancer ──────────────────────────────────────────────────
resource "aws_lb" "this" {
  name                             = local.name
  load_balancer_type               = "network"
  subnets                          = var.public_subnet_ids
  enable_cross_zone_load_balancing = true
  tags                             = var.tags
}

resource "aws_lb_target_group" "plain" {
  name        = "${local.name}-1883"
  port        = 1883
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "ip"
  health_check {
    protocol = "TCP"
    port     = "1883"
  }
  tags = var.tags
}

resource "aws_lb_listener" "plain" {
  load_balancer_arn = aws_lb.this.arn
  port              = 1883
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.plain.arn
  }
}

resource "aws_lb_listener" "tls" {
  count             = local.tls ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 8883
  protocol          = "TLS"
  certificate_arn   = var.certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.plain.arn
  }
}

# ── ECS task + service ─────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${local.name}"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_ecs_task_definition" "this" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = var.execution_role_arn

  volume {
    name = "mosquitto"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.this.id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.this.id
        iam             = "DISABLED"
      }
    }
  }

  container_definitions = jsonencode([
    {
      name       = "config-init"
      image      = "busybox:1.36"
      essential  = false
      entryPoint = ["sh", "-c"]
      command    = ["mkdir -p /mosquitto/config /mosquitto/data && printf '%s' \"$CONF\" > /mosquitto/config/mosquitto.conf"]
      environment = [
        { name = "CONF", value = local.conf }
      ]
      mountPoints = [{ sourceVolume = "mosquitto", containerPath = "/mosquitto" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "init"
        }
      }
    },
    {
      name      = "mosquitto"
      image     = var.image
      essential = true
      portMappings = [
        { containerPort = 1883, protocol = "tcp" }
      ]
      dependsOn = [
        { containerName = "config-init", condition = "COMPLETE" }
      ]
      mountPoints = [{ sourceVolume = "mosquitto", containerPath = "/mosquitto" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "mosquitto"
        }
      }
    }
  ])
  tags = var.tags
}

resource "aws_ecs_service" "this" {
  name            = "mqtt"
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.broker.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.plain.arn
    container_name   = "mosquitto"
    container_port   = 1883
  }

  health_check_grace_period_seconds = 60

  lifecycle {
    ignore_changes = [task_definition]
  }
  depends_on = [aws_efs_mount_target.this, aws_lb_listener.plain]
  tags       = var.tags
}

output "nlb_dns_name" { value = aws_lb.this.dns_name }
output "nlb_zone_id" { value = aws_lb.this.zone_id }
output "security_group_id" { value = aws_security_group.broker.id }
output "endpoint_plain" { value = "mqtt://${aws_lb.this.dns_name}:1883" }
output "endpoint_tls" { value = local.tls ? "mqtts://${aws_lb.this.dns_name}:8883" : null }
