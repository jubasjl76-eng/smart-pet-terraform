variable "environment" { type = string }
variable "region" { type = string }

variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "private_subnet_ids" { type = list(string) }

variable "cluster_arn" { type = string }
variable "cluster_name" { type = string }
variable "execution_role_arn" { type = string }

variable "image" {
  description = "Broker image. eclipse-mosquitto:2 for dev; a custom EMQX/mosquitto image for prod."
  type        = string
  default     = "eclipse-mosquitto:2"
}
variable "cpu" {
  type    = number
  default = 256
}
variable "memory" {
  type    = number
  default = 512
}
variable "desired_count" {
  type    = number
  default = 1
}

variable "certificate_arn" {
  description = "ACM cert for the :8883 TLS listener. \"\" = plain :1883 only (dev)."
  type        = string
  default     = ""
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the broker ports (edge bridges, offices). Devices usually go via the edge gateway."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "dev_allow_anonymous" {
  description = "dev only — mosquitto listener with allow_anonymous true. prod must run an auth backend."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
