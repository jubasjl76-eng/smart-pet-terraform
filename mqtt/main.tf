# Terraform Configuration for MQTT Broker
# EMQX or Mosquitto for IoT device communication

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
  default     = "smart-pet"
}

variable "environment" {
  description = "Environment"
  type        = string
  default     = "prod"
}

variable "mqtt_broker_type" {
  description = "MQTT Broker type: emqx or mosquitto"
  type        = string
  default     = "mosquitto"
}

# ============ PROVIDER ============
provider "aws" {
  region = var.aws_region
}

# ============ VPC (reuse existing or create new) ============
# Assumes VPC already exists from main.tf
# Add VPC ID from main infrastructure
variable "vpc_id" {
  description = "VPC ID to deploy MQTT broker in"
  type        = string
  default     = "" # Set from main terraform or pass as variable
}

variable "subnet_ids" {
  description = "Subnet IDs for MQTT broker"
  type        = list(string)
  default     = []
}

# ============ SECURITY GROUP ============
resource "aws_security_group" "mqtt" {
  name        = "${var.project_name}-mqtt-sg"
  description = "Security group for MQTT Broker"
  vpc_id      = var.vpc_id
  
  # MQTT (1883)
  ingress {
    from_port   = 1883
    to_port     = 1883
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "MQTT"
  }
  
  # MQTT over WebSocket (8083)
  ingress {
    from_port   = 8083
    to_port     = 8083
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "MQTT WebSocket"
  }
  
  # MQTT TLS (8883)
  ingress {
    from_port   = 8883
    to_port     = 8883
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "MQTT TLS"
  }
  
  # EMQX Dashboard (18083)
  ingress {
    from_port   = 18083
    to_port     = 18083
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "EMQX Dashboard"
  }
  
  # SSH (22)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH"
  }
  
  # Outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name        = "${var.project_name}-mqtt-sg"
    Environment = var.environment
  }
}

# ============ ECS CLUSTER FOR MQTT (Optional - for scaling) ============
resource "aws_ecs_cluster" "mqtt" {
  name = "${var.project_name}-mqtt-${var.environment}"
  
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
  
  tags = {
    Name        = "${var.project_name}-mqtt-cluster"
    Environment = var.environment
  }
}

# ============ SIMPLE EC2 MQTT BROKER ============
resource "aws_instance" "mqtt_broker" {
  count         = var.vpc_id != "" ? 1 : 0
  ami           = "ami-0c55b159cbfafe1f0" # Amazon Linux 2
  instance_type = "t3.micro"
  subnet_id     = var.subnet_ids[0]
  
  vpc_security_group_ids = [aws_security_group.mqtt.id]
  
  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              
              # Install Docker
              amazon-linux-extras install docker -y
              systemctl start docker
              systemctl enable docker
              
              # Install Docker Compose
              curl -L "https://github.com/docker/compose/releases/download/v2.24.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
              chmod +x /usr/local/bin/docker-compose
              
              # Create MQTT broker directory
              mkdir -p /opt/mqtt
              cd /opt/mqtt
              
              # Create docker-compose.yml for Mosquitto
              cat > docker-compose.yml << 'MOSQUITTO'
              version: '3.8'
              
              services:
                mosquitto:
                  image: eclipse-mosquitto:2
                  container_name: smart-pet-mosquitto
                  ports:
                    - "1883:1883"
                    - "8883:8883"
                    - "8083:8083"
                  volumes:
                    - ./mosquitto.conf:/mosquitto/config/mosquitto.conf
                    - ./data:/mosquitto/data
                    - ./logs:/mosquitto/log
                  restart: unless-stopped
                  networks:
                    - mqtt-network
                
                # EMQX alternative (uncomment to use)
                # emqx:
                #   image: emqx/emqx:latest
                #   container_name: smart-pet-emqx
                #   ports:
                #     - "1883:1883"
                #     - "8883:8883"
                #     - "8083:8083"
                #     - "18083:18083"
                #   environment:
                #     - EMQX_NAME=emqx
                #     - EMQX_HOST=127.0.0.1
                #     - EMQX_DASHBOARD__DEFAULT_USERNAME=admin
                #     - EMQX_DASHBOARD__DEFAULT_PASSWORD=public
                #   volumes:
                #     - ./emqx/data:/opt/emqx/data
                #     - ./emqx/log:/opt/emqx/log
                #   restart: unless-stopped
                
              networks:
                mqtt-network:
                  driver: bridge
              MOSQUITTO
              
              # Create Mosquitto config
              cat > mosquitto.conf << 'CONFIG'
              listener 1883
              allow_anonymous true
              
              listener 8883
              allow_anonymous true
              
              # WebSocket support
              listener 8083
              protocol websockets
              allow_anonymous true
              
              # Persistence
              persistence true
              persistence_location /mosquitto/data/
              
              # Logging
              log_dest stdout
              log_type error
              log_type warning
              log_type notice
              log_type information
              CONFIG
              
              # Start MQTT broker
              docker-compose up -d
              
              # Create systemd service
              cat > /etc/systemd/system/mqtt-broker.service << 'SERVICE'
              [Unit]
              Description=MQTT Broker for Smart Pet
              After=docker.service
              Requires=docker.service
              
              [Service]
              Type=oneshot
              RemainAfterExit=yes
              WorkingDirectory=/opt/mqtt
              ExecStart=/usr/local/bin/docker-compose up -d
              ExecStop=/usr/local/bin/docker-compose down
              TimeoutStartSec=0
              
              [Install]
              WantedBy=multi-user.target
              SERVICE
              
              systemctl daemon-reload
              systemctl enable mqtt-broker
              systemctl start mqtt-broker
              EOF
  
  tags = {
    Name        = "${var.project_name}-mqtt-broker"
    Environment = var.environment
    Project     = var.project_name
  }
}

# ============ ELASTIC IP ============
resource "aws_eip" "mqtt" {
  count  = var.vpc_id != "" ? 1 : 0
  domain = "vpc"
  
  tags = {
    Name        = "${var.project_name}-mqtt-eip"
    Environment = var.environment
  }
}

resource "aws_eip_association" "mqtt" {
  count         = var.vpc_id != "" ? 1 : 0
  instance_id   = aws_instance.mqtt_broker[0].id
  allocation_id = aws_eip.mqtt[0].id
}

# ============ OUTPUTS ============
output "mqtt_broker_endpoint" {
  description = "MQTT Broker endpoint"
  value       = var.vpc_id != "" ? "mqtt://${aws_eip.mqtt[0].public_ip}:1883" : "Not deployed - set vpc_id"
}

output "mqtt_websocket_endpoint" {
  description = "MQTT WebSocket endpoint"
  value       = var.vpc_id != "" ? "ws://${aws_eip.mqtt[0].public_ip}:8083" : "Not deployed - set vpc_id"
}

output "mqtt_tls_endpoint" {
  description = "MQTT TLS endpoint"
  value       = var.vpc_id != "" ? "mqtts://${aws_eip.mqtt[0].public_ip}:8883" : "Not deployed - set vpc_id"
}
