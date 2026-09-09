# cdn — REUSABLE. One private S3 bucket + a CloudFront distribution reading it
# through an Origin Access Control. `spa = true` rewrites 403/404 to
# /index.html (dashboard); `spa = false` serves files as-is (hls / firmware /
# snapshots / buyer-photos).
#
# A custom domain needs `aliases` + an ACM cert IN us-east-1 (CloudFront's
# requirement). Without them the distribution uses its *.cloudfront.net name.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "name" { type = string } # "assets" | "dashboard" | ...
variable "environment" { type = string }
variable "spa" {
  type    = bool
  default = false
}
variable "price_class" {
  type    = string
  default = "PriceClass_100"
}
variable "default_ttl" {
  type    = number
  default = 3600
}
variable "aliases" {
  type    = list(string)
  default = []
}
variable "certificate_arn" {
  description = "ACM cert in us-east-1. Required if aliases is non-empty."
  type        = string
  default     = ""
}
variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  bucket_name = "smart-pet-${var.environment}-${var.name}"
  use_acm     = length(var.aliases) > 0 && var.certificate_arn != ""
}

resource "aws_s3_bucket" "this" {
  bucket = local.bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_cloudfront_origin_access_control" "this" {
  name                              = local.bucket_name
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = local.bucket_name
  price_class         = var.price_class
  default_root_object = var.spa ? "index.html" : null
  aliases             = var.aliases
  tags                = var.tags

  origin {
    domain_name              = aws_s3_bucket.this.bucket_regional_domain_name
    origin_id                = "s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  default_cache_behavior {
    target_origin_id       = "s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    min_ttl                = 0
    default_ttl            = var.default_ttl
    max_ttl                = 86400
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  dynamic "custom_error_response" {
    for_each = var.spa ? [403, 404] : []
    content {
      error_code            = custom_error_response.value
      response_code         = 200
      response_page_path    = "/index.html"
      error_caching_min_ttl = 10
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = local.use_acm ? null : true
    acm_certificate_arn            = local.use_acm ? var.certificate_arn : null
    ssl_support_method             = local.use_acm ? "sni-only" : null
    minimum_protocol_version       = local.use_acm ? "TLSv1.2_2021" : null
  }
}

data "aws_iam_policy_document" "bucket" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json
}

output "bucket" { value = aws_s3_bucket.this.id }
output "bucket_arn" { value = aws_s3_bucket.this.arn }
output "distribution_id" { value = aws_cloudfront_distribution.this.id }
output "domain_name" { value = aws_cloudfront_distribution.this.domain_name }
