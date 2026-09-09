# secrets — the app secret container (JWT_SECRET, provider API keys, the DB URL).
# Terraform creates the secret; the VALUE is set out of band (console / CLI /
# CI), so nothing sensitive lives in state or the repo. RDS manages its own
# master password (see modules/database), so it is not here.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "environment" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "aws_secretsmanager_secret" "app" {
  name                    = "smart-pet/${var.environment}/app"
  description             = "Smart Pet backend app secrets (${var.environment}) — value set out of band"
  recovery_window_in_days = 7
  tags                    = var.tags
}

# A placeholder version so the secret is never empty. Real values are set with
#   aws secretsmanager put-secret-value --secret-id smart-pet/<env>/app --secret-string @secrets.json
resource "aws_secretsmanager_secret_version" "seed" {
  secret_id     = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({ PLACEHOLDER = "set-me" })

  lifecycle {
    ignore_changes = [secret_string] # do not clobber the real value on the next apply
  }
}

# Policy doc a task role attaches to read this secret.
data "aws_iam_policy_document" "read" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.app.arn]
  }
}

output "app_secret_arn" {
  value = aws_secretsmanager_secret.app.arn
}

output "read_policy_json" {
  value = data.aws_iam_policy_document.read.json
}
