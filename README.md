# smart-pet-terraform

Infrastructure as code for the Smart Pet cloud (Phase 10). Rebuilt from the
original single-EC2 toy (kept as `legacy/single-ec2.tf.txt`) into a
module + per-environment layout.

## Layout

```
bootstrap/          S3 state bucket + DynamoDB lock (run once, local state)
modules/
  network/          VPC · 2×AZ public+private subnets · IGW · NAT · S3 endpoint
  ...               database, mqtt-broker, ecs-cluster, ecs-service, alb, cdn,
                    dns, ecr, secrets, observability — added in later slices
envs/
  dev/              backend.tf (state key=dev) · main.tf · dev.tfvars
  prod/             (later)
.github/workflows/ci.yml   fmt + validate per stack
legacy/             the pre-Phase-10 single-EC2 config, for reference only
```

## First run

```bash
cd bootstrap
terraform init
terraform apply            # creates smart-pet-tfstate + smart-pet-tflock
```

Then each environment uses the S3 backend:

```bash
cd envs/dev
terraform init             # reads backend.tf
terraform plan -var-file=dev.tfvars
terraform apply -var-file=dev.tfvars
```

CI runs `terraform fmt -check -recursive` and, per stack,
`terraform init -backend=false` + `terraform validate`. `terraform plan` in CI
is off until GitHub → AWS OIDC is wired (the CI/CD slice); it needs real
credentials.

## Environments

| | `dev` | `prod` |
|---|---|---|
| VPC CIDR | `10.10.0.0/16` | `10.20.0.0/16` (later) |
| NAT | one for the VPC | one per AZ |
| RDS | `db.t4g.micro`, single-AZ | `db.t4g.small`+, Multi-AZ |
| Broker | Mosquitto ×1 | EMQX ×2+ |
| Backend | ×1 | ×2, autoscale 2–6 |

## Slices

- [x] **foundation** — bootstrap, `modules/network`, `envs/dev`, CI (this PR)
- [x] **database + secrets + ecr** — RDS Postgres (RDS-managed master pw), app secret container, ECR repos
- [x] **ecs-cluster + reusable ecs-service + alb** + backend on Fargate
- [ ] mqtt-broker (Mosquitto) + dns
- [ ] cdn (S3/CloudFront) + observability
- [ ] GitHub → AWS OIDC + reusable deploy workflow (test → image → ECR → ECS)
- [ ] `prod` env + scale settings
