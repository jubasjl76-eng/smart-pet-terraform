variable "name" {
  description = "Service name, e.g. \"backend\"."
  type        = string
}
variable "environment" { type = string }
variable "region" { type = string }

variable "cluster_arn" { type = string }
variable "cluster_name" { type = string }
variable "execution_role_arn" { type = string }

variable "image" {
  description = "Full image ref, e.g. <acct>.dkr.ecr.<region>.amazonaws.com/smart-pet/backend:latest"
  type        = string
}
variable "container_port" { type = number }
variable "cpu" {
  type    = number
  default = 512
}
variable "memory" {
  type    = number
  default = 1024
}
variable "desired_count" {
  type    = number
  default = 1
}

variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "alb_security_group_id" { type = string }
variable "alb_listener_arn" { type = string }
variable "listener_priority" { type = number }

variable "host_header" {
  description = "Host to route on; \"*\" matches anything."
  type        = string
  default     = "*"
}
variable "path_pattern" {
  type    = string
  default = "/*"
}
variable "health_check_path" {
  type    = string
  default = "/health"
}

variable "environment_vars" {
  type    = map(string)
  default = {}
}
variable "secret_refs" {
  description = "name => Secrets Manager valueFrom ARN (arn:...:secret:NAME:JSONKEY::)."
  type        = map(string)
  default     = {}
}
variable "task_role_policy_json" {
  description = "Extra IAM policy for the task role (e.g. publish to MQTT relay, read the app secret). \"\" = none."
  type        = string
  default     = ""
}

variable "min_count" {
  type    = number
  default = 1
}
variable "max_count" {
  type    = number
  default = 1
}
variable "cpu_target" {
  type    = number
  default = 60
}

variable "log_retention_days" {
  type    = number
  default = 30
}
variable "tags" {
  type    = map(string)
  default = {}
}
