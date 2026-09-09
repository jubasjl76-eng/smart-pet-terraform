# ecs-service — REUSABLE. One Fargate service behind a shared ALB listener:
# task definition, task role, service SG, target group + listener rule, logs,
# and CPU target-tracking autoscaling when max_count > min_count.

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
  full = "smart-pet-${var.environment}-${var.name}"
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${local.full}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# ── task role ────────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task" {
  name               = "${local.full}-task"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "task_extra" {
  count  = var.task_role_policy_json != "" ? 1 : 0
  name   = "extra"
  role   = aws_iam_role.task.id
  policy = var.task_role_policy_json
}

# ── security group (ALB → container port) ────────────────────────────────────
resource "aws_security_group" "this" {
  name        = "${local.full}-svc"
  description = "${local.full} service"
  vpc_id      = var.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "from_alb" {
  security_group_id            = aws_security_group.this.id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = var.alb_security_group_id
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ── task definition ─────────────────────────────────────────────────────────
resource "aws_ecs_task_definition" "this" {
  family                   = local.full
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = var.name
      image     = var.image
      essential = true
      portMappings = [
        { containerPort = var.container_port, protocol = "tcp" }
      ]
      environment = [for k, v in var.environment_vars : { name = k, value = v }]
      secrets     = [for k, v in var.secret_refs : { name = k, valueFrom = v }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = var.name
        }
      }
      healthCheck = {
        command     = ["CMD-SHELL", "wget -qO- http://localhost:${var.container_port}${var.health_check_path} || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }
    }
  ])
  tags = var.tags
}

# ── target group + listener rule ────────────────────────────────────────────
resource "aws_lb_target_group" "this" {
  name        = substr("${local.full}", 0, 32)
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = var.health_check_path
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200-399"
  }
  tags = var.tags
}

resource "aws_lb_listener_rule" "this" {
  listener_arn = var.alb_listener_arn
  priority     = var.listener_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
  condition {
    host_header {
      values = [var.host_header]
    }
  }
  condition {
    path_pattern {
      values = [var.path_pattern]
    }
  }
}

# ── service ────────────────────────────────────────────────────────────────
resource "aws_ecs_service" "this" {
  name            = var.name
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.this.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = var.name
    container_port   = var.container_port
  }

  health_check_grace_period_seconds  = 60
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  lifecycle {
    ignore_changes = [task_definition] # CI deploys new task defs; TF owns everything else
  }
  depends_on = [aws_lb_listener_rule.this]
  tags       = var.tags
}

# ── autoscaling (only when there is room to scale) ──────────────────────────
resource "aws_appautoscaling_target" "this" {
  count              = var.max_count > var.min_count ? 1 : 0
  service_namespace  = "ecs"
  resource_id        = "service/${var.cluster_name}/${var.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.min_count
  max_capacity       = var.max_count
}

resource "aws_appautoscaling_policy" "cpu" {
  count              = var.max_count > var.min_count ? 1 : 0
  name               = "${local.full}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = var.cpu_target
    scale_in_cooldown  = 120
    scale_out_cooldown = 60
  }
}

output "security_group_id" { value = aws_security_group.this.id }
output "target_group_arn" { value = aws_lb_target_group.this.arn }
output "service_name" { value = aws_ecs_service.this.name }
output "task_role_arn" { value = aws_iam_role.task.arn }
output "log_group" { value = aws_cloudwatch_log_group.this.name }

output "target_group_arn_suffix" {
  value = aws_lb_target_group.this.arn_suffix
}
