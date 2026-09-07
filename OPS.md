# Keel shop — operator notes

Bring-up is two applies: one for the state bucket, one for the shop. Tasks start at zero copies until you push an image from a machine that has internet. The VPC does not.

## What you need before typing terraform

AWS creds in the shell. A public hosted zone and a name inside it (`fqdn` + `dns_zone`). An inbox for `pager_email` — SNS will sit Pending until you click Confirm. Docker on a laptop. Terraform 1.6+.

```bash
aws sts get-caller-identity
terraform -chdir=bootstrap init
terraform -chdir=bootstrap apply
terraform -chdir=bootstrap output -raw backend_hcl > backend.hcl
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl
terraform plan -out=shop.tfplan
terraform apply shop.tfplan
./scripts/push-api.sh v1
# image_uri = "<registry>:v1"
# replica_min = 2
terraform apply
```

The state bucket is created with local state. That is intentional. A backend cannot invent its own bucket.

`aws_lb_listener.secure` takes the ARN from `aws_acm_certificate_validation.shop`. A still-pending cert returns `UnsupportedCertificate`.

Tear-down: turn `deletion_protection` off first, then destroy the shop, then destroy bootstrap.

## How a request reaches Postgres

Browser → public ALB (ingress subnets) → peer rule to Fargate in svc subnets → peer rule to Postgres in persist subnets. `/status` opens a TCP socket to `DB_HOST`. That value is injected from `/keel-shop/pg-host` at task start.

The isolated route table has no `0.0.0.0/0`. ECR, logs, Secrets Manager, SSM, and S3 are VPC endpoints in both svc AZs. If someone expects `npm` or `public.ecr.aws` from inside a task, that is a product bug, not an outage.

## Money ($150 idle, us-east-1 list × 730h)

Skipped: NAT (~$35), Multi-AZ Postgres (~+$12), Spot (~$6). Bought: five interface endpoints in two AZs (~$73), ALB + two public IPv4s (~$24), `db.t4g.micro` (~$12), two 0.25/0.5 GB on-demand tasks (~$18). Quiet month lands around $120–135. A second NAT does not help ECR if both svc subnets still share one table.

## When the database AZ dies

Quote **90 minutes** to a teammate who is not already watching Slack. That covers the 3-minute empty-target alarm, them noticing, a 15–30 minute restore of 20 GB, the SSM write, and drain. Snapshot RPO is up to a day (`backup_window` 08:00–09:00 UTC). PITR is ~5 minutes RPO, same RTO class.

```bash
./scripts/rewind-pg.sh keel-shop-pg keel-shop-pg-rewind
```

Do not put `snapshot_identifier` on `aws_db_instance.pg`. Do not rewrite the task family. The SSM parameter ignores value drift so the next apply will not stomp the rewound host.

## Process user

`local.numeric_uid` is `1000:1000`. `var.run_as` must match. The task-definition precondition fails apply otherwise. Dockerfile `USER shop` is extra. `privileged` / read-only root / dropped caps do not change UID.

## What pages

`task-never-started` (EventBridge): new tasks STOPPED because the image or secret could not load. `no-ready-targets`: `/status` is 503, usually Postgres. Confirm the SNS email.

## What I actually ran

`terraform fmt -recursive`. Both configs `init -backend=false && validate` succeeded on AWS provider 5.100.0. No `plan` against a real account from this laptop.
