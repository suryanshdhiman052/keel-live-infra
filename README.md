# Keel live — budget-capped AWS shop API

Public repository: https://github.com/suryanshdhiman052/keel-live-infra

Three Terraform modules:

| Module | Owns |
|---|---|
| `networking` | VPC `10.81.0.0/16`, public/app/db subnets, **no NAT**, VPC endpoints, SG peer rules |
| `compute` | ECR, S3 `objects/*`, ACM+HTTPS ALB, SSM DB endpoint, ECS Fargate, IAM, CPU autoscaling |
| `database` | Private single-AZ Postgres (`db.t4g.micro`) |

Follow **[RUNBOOK.md](./RUNBOOK.md)**. Do not start from this README alone.
