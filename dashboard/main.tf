# Terraform Configuration for Backoffice Dashboard
# AWS S3 + CloudFront Static Website Hosting

terraform {
  required_version = ">= 1.0.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ============ VARIABLES ============
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "smart-pet-dashboard"
}

variable "environment" {
  description = "Environment"
  type        = string
  default     = "prod"
}

# ============ PROVIDER ============
provider "aws" {
  region = var.aws_region
}

# ============ S3 BUCKET FOR DASHBOARD ============
resource "aws_s3_bucket" "dashboard" {
  bucket = "${var.project_name}-${var.environment}"
  
  tags = {
    Name        = var.project_name
    Environment = var.environment
  }
}

resource "aws_s3_bucket_ownership_controls" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id
  
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_public_access_block" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id
  
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_versioning" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id
  
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_website_configuration" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id
  
  index_document {
    suffix = "index.html"
  }
  
  error_document {
    key = "index.html"
  }
}

# ============ DASHBOARD POLICY ============
resource "aws_s3_bucket_policy" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.dashboard.arn}/*"
      }
    ]
  })
}

# ============ CLOUDFRONT ============
resource "aws_cloudfront_distribution" "dashboard" {
  enabled             = true
  price_class         = "PriceClass_All"
  comment             = "Smart Pet Dashboard"
  
  origin {
    domain_name = aws_s3_bucket_website_configuration.dashboard.website_endpoint
    origin_id   = "S3-dashboard"
    
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1", "TLSv1.1", "TLSv1.2"]
    }
  }
  
  default_root_object = "index.html"
  
  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3-dashboard"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true
    
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }
  
  price_class = "PriceClass_All"
  
  tags = {
    Name        = var.project_name
    Environment = var.environment
  }
}

# ============ OUTPUTS ============
output "bucket_name" {
  description = "S3 bucket name"
  value       = aws_s3_bucket.dashboard.id
}

output "cloudfront_url" {
  description = "CloudFront distribution URL"
  value       = "https://${aws_cloudfront_distribution.dashboard.domain_name}"
}

output "s3_website_url" {
  description = "S3 website URL (for testing)"
  value       = "http://${aws_s3_bucket_website_configuration.dashboard.website_endpoint}"
}
