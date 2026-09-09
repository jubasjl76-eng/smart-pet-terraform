# oidc — the GitHub Actions OIDC provider + IAM roles GitHub assumes with no
# long-lived keys:
#   * terraform_role  — assumed by smart-pet-terraform to plan/apply the infra
#   * deploy roles     — one per app repo, scoped to pushing its image + rolling
#                        its ECS service
#
# terraform_role is broad on purpose (it manages everything). Deploy roles are
# tight: ECR push to one repo, ecs update/describe/register, run the migration
# task, PassRole for the exec + task roles.

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
variable "github_org" {
  type    = string
  default = "jubasjl76-eng"
}
variable "terraform_repo" {
  type    = string
  default = "smart-pet-terraform"
}
variable "deploy_repos" {
  description = "service name => { repo, ref }. ref e.g. \"ref:refs/heads/development\" or \"*\"."
  type = map(object({
    repo = string
    ref  = string
  }))
  default = {}
}
variable "ecr_repository_arns" {
  type    = list(string)
  default = []
}
variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
  tags            = var.tags
}

# ── terraform role ─────────────────────────────────────────────────────────
data "aws_iam_policy_document" "tf_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.terraform_repo}:*"]
    }
  }
}

resource "aws_iam_role" "terraform" {
  name               = "smart-pet-${var.environment}-gha-terraform"
  assume_role_policy = data.aws_iam_policy_document.tf_assume.json
  tags               = var.tags
}

# Broad — it applies the whole stack. Tighten later with a scoped policy if
# required. PowerUser + IAM (PowerUser excludes IAM).
resource "aws_iam_role_policy_attachment" "tf_power" {
  role       = aws_iam_role.terraform.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}
resource "aws_iam_role_policy_attachment" "tf_iam" {
  role       = aws_iam_role.terraform.name
  policy_arn = "arn:aws:iam::aws:policy/IAMFullAccess"
}

# ── deploy roles (one per app repo) ────────────────────────────────────────
data "aws_iam_policy_document" "deploy_assume" {
  for_each = var.deploy_repos
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${each.value.repo}:${each.value.ref}"]
    }
  }
}

data "aws_iam_policy_document" "deploy_perms" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
      "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
    ]
    resources = length(var.ecr_repository_arns) > 0 ? var.ecr_repository_arns : ["*"]
  }
  statement {
    sid = "EcsDeploy"
    actions = [
      "ecs:DescribeServices", "ecs:DescribeTaskDefinition", "ecs:DescribeTasks",
      "ecs:RegisterTaskDefinition", "ecs:UpdateService", "ecs:RunTask",
      "ecs:ListTasks",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "PassExecAndTaskRoles"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/smart-pet-${var.environment}-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  for_each           = var.deploy_repos
  name               = "smart-pet-${var.environment}-gha-deploy-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.deploy_assume[each.key].json
  tags               = var.tags
}

resource "aws_iam_role_policy" "deploy" {
  for_each = var.deploy_repos
  name     = "deploy"
  role     = aws_iam_role.deploy[each.key].id
  policy   = data.aws_iam_policy_document.deploy_perms.json
}

output "provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}
output "terraform_role_arn" {
  value = aws_iam_role.terraform.arn
}
output "deploy_role_arns" {
  value = { for k, r in aws_iam_role.deploy : k => r.arn }
}
