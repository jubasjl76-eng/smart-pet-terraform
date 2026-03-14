# Smart Pet Ecosystem - Terraform Configuration
# Unified infrastructure for all Smart Pet services

terraform {
  required_version = ">= 1.0.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  
  backend "local" {
    path = "terraform.tfstate"
  }
}

# ============ VARIABLES ============
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "project_name" {
  description = "Project name for tagging"
  type        = string
  default     = "smart-pet"
}

variable "environment" {
  description = "Environment (dev/staging/prod)"
  type        = string
  default     = "prod"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

# ============ PROVIDER ============
provider "aws" {
  region = var.aws_region
}

# ============ VPC ============
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  
  tags = {
    Name        = "${var.project_name}-vpc"
    Environment = var.environment
  }
}

resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true
  
  tags = {
    Name        = "${var.project_name}-subnet-1"
    Environment = var.environment
  }
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "${var.aws_region}b"
  map_public_ip_on_launch = true
  
  tags = {
    Name        = "${var.project_name}-subnet-2"
    Environment = var.environment
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  
  tags = {
    Name        = "${var.project_name}-igw"
    Environment = var.environment
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  
  tags = {
    Name        = "${var.project_name}-rt"
    Environment = var.environment
  }
}

resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

# ============ SECURITY GROUPS ============
resource "aws_security_group" "api" {
  name        = "${var.project_name}-api-sg"
  description = "Security group for Smart Pet API"
  vpc_id      = aws_vpc.main.id
  
  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH"
  }
  
  # HTTP
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP"
  }
  
  # HTTPS
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS"
  }
  
  # Unified API (3000)
  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Smart Pet Unified API"
  }
  
  # Outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name        = "${var.project_name}-api-sg"
    Environment = var.environment
  }
}

# ============ EC2 INSTANCE ============
resource "aws_instance" "api_server" {
  ami           = "ami-0c55b159cbfafe1f0" # Amazon Linux 2
  instance_type = var.instance_type
  subnet_id     = aws_subnet.public_1.id
  
  vpc_security_group_ids = [aws_security_group.api.id]
  
  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y git docker
              systemctl start docker
              systemctl enable docker
              
              # Install Node.js 20
              curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
              yum install -y nodejs
              
              # Pull/Clone unified backend
              cd /opt
              git clone https://github.com/jubasjl76-eng/smart-pet-backend.git
              cd smart-pet-backend
              npm install
              
              # Create systemd service
              cat > /etc/systemd/system/smart-pet.service << 'SERVICE'
              [Unit]
              Description=Smart Pet Unified API
              After=network.target
              
              [Service]
              Type=simple
              User=root
              WorkingDirectory=/opt/smart-pet-backend
              ExecStart=/usr/bin/npm run start
              Restart=always
              Environment=PORT=3000
              Environment=API_KEY=smart-pet-prod-key-2026
              
              [Install]
              WantedBy=multi-user.target
              SERVICE
              
              systemctl daemon-reload
              systemctl enable smart-pet
              systemctl start smart-pet
              
              # Install Docker Compose for future scaling
              curl -L "https://github.com/docker/compose/releases/download/v2.24.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
              chmod +x /usr/local/bin/docker-compose
              EOF
  
  tags = {
    Name        = "${var.project_name}-api-server"
    Environment = var.environment
    Project     = var.project_name
  }
}

# ============ ELASTIC IP ============
resource "aws_eip" "api" {
  instance = aws_instance.api_server.id
  domain   = "vpc"
  
  tags = {
    Name        = "${var.project_name}-eip"
    Environment = var.environment
  }
}

# ============ OUTPUTS ============
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "api_server_ip" {
  description = "Public IP of API server"
  value       = aws_eip.api.public_ip
}

output "api_url" {
  description = "Unified API URL"
  value       = "http://${aws_eip.api.public_ip}:3000"
}

output "health_endpoint" {
  description = "Health check endpoint"
  value       = "http://${aws_eip.api.public_ip}:3000/health"
}
