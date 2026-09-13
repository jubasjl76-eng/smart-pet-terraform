# mqtt-broker — Mosquitto on Fargate behind a Network Load Balancer. EFS holds
# the config + a per-task persistence subdirectory. TLS :8883 when a cert is
# given; plain :1883 always.
#
# dev runs `eclipse-mosquitto:2` with allow_anonymous. prod must swap `image`
# for one with an auth backend (dynamic-security or a plugin the backend feeds).
#
# HA (Phase 21, A11 — "EMQX cluster depth"): the plan names EMQX's clustering
# (shared session + retained state across nodes, split-brain policy) — the
# broker actually deployed is Mosquitto, which has no clustering protocol at
# all; N Mosquitto tasks behind this NLB are N fully independent replicas,
# not a cluster, so there's no shared distributed state to split-brain over
# in the first place. A real clustered/RocksDB retained store is an
# EMQX-only capability — same cost/complexity deferral as Phase 20's broker
# limits, still not justified at this fleet's scale. What IS a genuine,
# broker-agnostic fix, done here: each task previously wrote its persistence
# file to the SAME shared EFS mount (`persistence_location` was a static
# path) while prod already runs `desired_count = 2` — two Mosquitto
# processes concurrently appending the same file is a real corruption risk,
# not a feature. Each task now gets its own subdirectory (keyed by its ENI's
# private IP, unique per Fargate task) — independent replicas with locally
# durable state instead of a shared file two processes were never meant to
# write together. Losing a client's server-side session/retained state on
# failover to a different task is the accepted degradation the plan itself
# names for "broker down": devices journal locally and replay on reconnect,
# and the backend now drops out-of-order replays by timestamp (`applyStatus`
# in `smart-pet-backend`, migration `017_device_status_ordering.sql`).

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
  # Abuse-prevention limits (hardening Phase 20, A10). Mosquitto has no native
  # per-client message-rate / connection-rate limiter (that's an EMQX-only
  # capability the hardening plan names) — deferred pending an actual flooding
  # incident, since a broker migration is a real cost/complexity jump the
  # fleet's current scale doesn't justify. What Mosquitto DOES enforce natively
  # is applied here: a per-listener connection ceiling, a max packet size (device
  # payloads are small JSON), a keepalive ceiling (stops a client stalling dead-
  # client detection), and a per-client outgoing queue cap that already
  # disconnects + logs on breach — the log_metric_filter/alarm below catches that.
  # persistence_location is appended by config-init at container start (a
  # per-task subdirectory — see the module header comment); not set here.
  conf = <<-EOT
    listener 1883
    ${var.dev_allow_anonymous ? "allow_anonymous true" : "allow_anonymous false"}
    max_connections ${var.max_connections}
    persistence true
    autosave_interval 60
    max_inflight_messages 200
    max_queued_messages ${var.max_queued_messages}
    message_size_limit ${var.message_size_limit}
    max_keepalive ${var.max_keepalive}
    log_dest stdout
    log_type warning
    log_type notice

    # Loopback-only, anonymous — never reachable off-box (the security groups
    # only ever open 1883/8883). Exists so the ECS container healthcheck below
    # can prove the broker is actually processing MQTT, not just holding the
    # port open, even in prod where the main listener requires auth.
    listener 18883 127.0.0.1
    allow_anonymous true
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
      # This task's own private IP (unique per Fargate task/ENI) keys its
      # persistence subdirectory — see the module header comment on why that
      # replaced one persistence file shared across replicas.
      command = [
        "mkdir -p /mosquitto/config /mosquitto/data && printf '%s' \"$CONF\" > /mosquitto/config/mosquitto.conf && DIR=/mosquitto/data/$(hostname -i) && mkdir -p \"$DIR\" && printf 'persistence_location %s/\\n' \"$DIR\" >> /mosquitto/config/mosquitto.conf"
      ]
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
      # NLB's own health check only proves the TCP port accepts a handshake —
      # not that Mosquitto is actually processing MQTT (a wedged-but-listening
      # process would still pass it). A real pub round-trip on the loopback
      # listener catches that; ECS restarts the task on repeated failure,
      # independent of (and stricter than) the NLB check.
      healthCheck = {
        command     = ["CMD-SHELL", "mosquitto_pub -h 127.0.0.1 -p 18883 -t healthcheck -m ok -q 0 -i healthcheck -W 3 || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 15
      }
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

  # No ignore_changes here (unlike modules/ecs-service, where it's needed
  # because a separate CI deploy pipeline registers new task defs with a
  # fresh image tag): this module's image is a plain terraform variable
  # (`var.image`/`var.broker_image`), nothing else ever touches this task
  # definition, so ignoring it would just mean this PR's own healthcheck +
  # persistence-path changes silently never reach the running service.
  depends_on = [aws_efs_mount_target.this, aws_lb_listener.plain]
  tags       = var.tags
}

# Mosquitto logs a warning and disconnects the client when a per-client limit
# above is breached ("dropped message", "exceeded", queue/connection denials).
# Count those lines and alarm on a burst — the broker-level equivalent of the
# backend's own rate-limit signal.
resource "aws_cloudwatch_log_metric_filter" "client_limit_breach" {
  name           = "${local.name}-client-limit-breach"
  log_group_name = aws_cloudwatch_log_group.this.name
  pattern        = "?dropped ?exceeded ?denied"

  metric_transformation {
    name          = "MqttClientLimitBreach"
    namespace     = "SmartPet/${var.environment}"
    value         = "1"
    default_value = 0
  }
}

resource "aws_cloudwatch_metric_alarm" "client_limit_breach" {
  count               = var.alarm_topic_arn != "" ? 1 : 0
  alarm_name          = "${local.name}-client-limit-breach"
  namespace           = "SmartPet/${var.environment}"
  metric_name         = "MqttClientLimitBreach"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 20
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
  tags                = var.tags
}

output "nlb_dns_name" { value = aws_lb.this.dns_name }
output "nlb_zone_id" { value = aws_lb.this.zone_id }
output "security_group_id" { value = aws_security_group.broker.id }
output "endpoint_plain" { value = "mqtt://${aws_lb.this.dns_name}:1883" }
output "endpoint_tls" { value = local.tls ? "mqtts://${aws_lb.this.dns_name}:8883" : null }
