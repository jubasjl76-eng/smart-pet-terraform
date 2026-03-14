# Smart Pet Terraform

Infrastructure as Code for the Smart Pet ecosystem.

## What's Included

- **VPC** - Virtual Private Cloud with public subnets
- **EC2** - Single server for unified API
- **Security Groups** - Firewall rules for API access
- **Elastic IP** - Static public IP

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
cd terraform
terraform init
```

4. Plan deployment:
```bash
terraform plan
```

5. Apply:
```bash
terraform apply
```

## Architecture

```
┌─────────────────────────────────────────────────┐
│                    Internet                       │
└─────────────────┬───────────────────────────────┘
                  │
            [Elastic IP]
                  │
        ┌─────────▼─────────┐
        │   EC2 Instance    │
        │  (t3.micro)       │
        │                   │
        │ ┌───────────────┐ │
        │ │ Unified API   │ │
        │ │ Port 3000     │ │
        │ └───────────────┘ │
        └─────────┬─────────┘
                  │
        ┌────────▼────────┐
        │   VPC (10.0.0.0) │
        │  Public Subnets   │
        │  eu-west-1a/b    │
        └──────────────────┘
```

## Services Deployed

| Service | Port | Description |
|---------|------|-------------|
| Unified API | 3000 | All devices, schedules, events |

## Variables

Edit `terraform.tfvars`:

```hcl
aws_region    = "eu-west-1"
project_name  = "smart-pet"
environment   = "prod"
instance_type = "t3.micro"
```

## Outputs

After deployment:
- `api_url` - Full API URL
- `api_server_ip` - Server IP
- `health_endpoint` - Health check URL

## Cost Estimate

- EC2 t3.micro: ~$8/month
- Elastic IP: Free
- Data transfer: ~$1/month

**Total: ~$9/month**

## Future Scaling

For production with high load:
1. Add Application Load Balancer
2. Use AWS Fargate or EKS
3. Add RDS for persistent storage
4. Add CloudFront CDN
5. Set up Auto Scaling

## License

MIT
