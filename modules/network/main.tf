# network — VPC with 2 public + 2 private subnets across two AZs, an IGW, one or
# more NAT gateways, and an S3 gateway endpoint (keeps ECR/S3 pulls off the NAT).

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs           = slice(data.aws_availability_zones.available.names, 0, 2)
  name          = "${var.project}-${var.environment}"
  nat_count     = var.single_nat ? 1 : length(local.azs)
  public_cidrs  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  private_cidrs = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 8)]
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = merge(var.tags, { Name = "${local.name}-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${local.name}-igw" })
}

resource "aws_subnet" "public" {
  for_each                = { for i, az in local.azs : az => i }
  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = local.public_cidrs[each.value]
  map_public_ip_on_launch = true
  tags                    = merge(var.tags, { Name = "${local.name}-public-${each.key}", Tier = "public" })
}

resource "aws_subnet" "private" {
  for_each          = { for i, az in local.azs : az => i }
  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = local.private_cidrs[each.value]
  tags              = merge(var.tags, { Name = "${local.name}-private-${each.key}", Tier = "private" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = merge(var.tags, { Name = "${local.name}-public" })
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${local.name}-nat-${count.index}" })
}

resource "aws_nat_gateway" "this" {
  count         = local.nat_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = values(aws_subnet.public)[count.index].id
  tags          = merge(var.tags, { Name = "${local.name}-nat-${count.index}" })
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  for_each = aws_subnet.private
  vpc_id   = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[local.single_nat_index[each.key]].id
  }
  tags = merge(var.tags, { Name = "${local.name}-private-${each.key}" })
}

locals {
  # each private subnet -> index of the NAT it routes through
  single_nat_index = {
    for i, az in local.azs : az => (var.single_nat ? 0 : i)
  }
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat([aws_route_table.public.id], [for rt in aws_route_table.private : rt.id])
  tags              = merge(var.tags, { Name = "${local.name}-s3" })
}
