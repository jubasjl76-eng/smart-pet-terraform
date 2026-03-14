# Smart Pet Terraform

Infrastructure as Code for the Smart Pet ecosystem.

## What's Included

- **VPC** - Virtual Private Cloud with public subnets
- **EC2** - Single server for unified API
- **MQTT Broker** - Eclipse Mosquitto for IoT device communication
- **S3 + CloudFront** - Static website hosting for dashboard
- **Security Groups** - Firewall rules for all services

## Structure

```
smart-pet-terraform/
├── main.tf          # VPC, EC2 for backend API
├── dashboard/       # S3 + CloudFront for dashboard
├── mqtt/           # MQTT broker for IoT devices
└── README.md
```

## Quick Start

1. Install Terraform:
```bash
brew install terraform
```

2. Configure AWS credentials:
```bash
aws configure
```

3. Initialize:
```bash
cd smart-pet-terraform
terraform init
```

4. Deploy main infrastructure (VPC + Backend):
```bash
terraform apply
```

5. Deploy MQTT broker (requires VPC ID from main):
```bash
cd mqtt
terraform init
terraform apply -var="vpc_id=<VPC_ID>" -var="subnet_ids=[<SUBNET_ID>]"
```

6. Deploy dashboard:
```bash
cd ../dashboard
terraform init
terraform apply
```

## Architecture

```
┌─────────────────────────────────────────────────┐
│                    Internet                       │
└─────────────────┬───────────────────────────────┘
                  │
        ┌─────────┼─────────┐
        │         │         │
   [CloudFront] [EIP]    [EIP]
        │         │         │
   ┌────▼────┐ ┌──▼──┐ ┌──▼──┐
   │   S3    │ │ MQTT│ │ API │
   │Dashboard│ │ :1883│ │:3000│
   └─────────┘ └──┬──┘ └──┬──┘
                  │      │
        ┌─────────▼──────▼─────────┐
        │       VPC (10.0.0.0)      │
        │    Public Subnets          │
        │    eu-west-1a/b          │
        └───────────────────────────┘
```

## Services Deployed

| Service | Port | Description |
|---------|------|-------------|
| Unified API | 3000 | All devices, schedules, events |
| MQTT Broker | 1883 | IoT device communication |
| MQTT WebSocket | 8083 | Web clients |
| MQTT TLS | 8883 | Secure MQTT |
| Dashboard | 80/443 | S3 + CloudFront |

## Variables

### Main (main.tf)
```hcl
aws_region    = "eu-west-1"
project_name  = "smart-pet"
environment   = "prod"
instance_type = "t3.micro"
```

### MQTT (mqtt/main.tf)
```hcl
vpc_id        = "vpc-xxxxxxxxx"
subnet_ids    = ["subnet-xxxxxxxx"]
mqtt_broker_type = "mosquitto"
```

### Dashboard (dashboard/main.tf)
```hcl
aws_region    = "eu-west-1"
project_name  = "smart-pet-dashboard"
environment   = "prod"
```

## Cost Estimate

- EC2 t3.micro: ~$8/month
- S3: ~$1/month
- CloudFront: ~$1/month
- Data transfer: ~$2/month

**Total: ~$12/month**

## Mobile App (EAS)

The mobile app uses **EAS (Expo Application Services)** instead of Terraform:

```bash
# Install EAS CLI
npm install -g eas-cli

# Login to Expo
eas login

# Configure project
eas build:configure

# Build for iOS
eas build --platform ios

# Build for Android
eas build --platform android

# Submit to App Store
eas submit
```

### EAS Build Configuration (eas.json)
```json
{
  "build": {
    "production": {
      "android": {
        "buildType": "app-bundle"
      },
      "ios": {
        "buildType": "release"
      }
    },
    "development": {
      "android": {
        "buildType": "debug"
      },
      "ios": {
        "buildType": "simulator"
      }
    }
  }
}
```

## Future Scaling

For production with high load:
1. Add Application Load Balancer
2. Use AWS Fargate or EKS
3. Add RDS for persistent storage
4. Set up Auto Scaling
5. Add Redis for caching/WebSocket

## License

MIT
