variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "allowed_security_group_ids" {
  description = "SGs allowed to reach 5432 (the backend service SG, added in the ecs slice)."
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "CIDRs allowed to reach 5432 (e.g. the VPC CIDR for dev)."
  type        = list(string)
  default     = []
}

variable "engine_version" {
  type    = string
  default = "16.6"
}

variable "parameter_group_family" {
  type    = string
  default = "postgres16"
}

variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "max_allocated_storage" {
  type    = number
  default = 100
}

variable "db_name" {
  type    = string
  default = "smartpet"
}

variable "master_username" {
  type    = string
  default = "smartpet"
}

variable "multi_az" {
  type    = bool
  default = false
}

variable "backup_retention_period" {
  type    = number
  default = 7
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "skip_final_snapshot" {
  type    = bool
  default = false
}

variable "performance_insights" {
  type    = bool
  default = false
}

# Pool sizing (hardening Phase 20, A12 #1). Set explicitly rather than left to
# RDS's auto-computed default (derived from instance memory) so the exact
# number is known in Terraform — callers use it (÷ instance count, with
# headroom) to size each service's pg.Pool `max`, instead of guessing.
variable "max_connections" {
  description = "Postgres max_connections. RDS's own default for db.t4g.micro/small is ~112/225; set below that for headroom (RDS reserves some for itself, superuser, monitoring)."
  type        = number
  default     = 80
}

variable "statement_timeout_ms" {
  description = "Server-side query timeout (defense in depth alongside the app's own PG_STATEMENT_TIMEOUT_MS). 0 = no limit."
  type        = number
  default     = 30000
}

variable "tags" {
  type    = map(string)
  default = {}
}
