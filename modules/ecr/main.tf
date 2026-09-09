# ecr — one image repository per service. Scan on push; expire untagged images
# and keep the last N tagged.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "repositories" {
  type    = set(string)
  default = ["backend", "sensors", "camera", "broker"]
}

variable "keep_last" {
  type    = number
  default = 15
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "aws_ecr_repository" "this" {
  for_each             = var.repositories
  name                 = "smart-pet/${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # dev-friendly; prod can flip this

  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "AES256"
  }
  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "expire untagged after 7 days"
        selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 7 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "keep the last ${var.keep_last} tagged"
        selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = var.keep_last }
        action       = { type = "expire" }
      },
    ]
  })
}

output "repository_urls" {
  value = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "repository_arns" {
  value = [for r in aws_ecr_repository.this : r.arn]
}
