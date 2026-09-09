variable "project" {
  type    = string
  default = "smart-pet"
}

variable "environment" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "single_nat" {
  description = "One NAT gateway for the whole VPC (cheap, dev). false = one per AZ."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
