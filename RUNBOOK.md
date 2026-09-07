# Keel live — engineer runbook

Stack: two-AZ VPC, **no NAT**, ECS Fargate (on-demand), single-AZ Postgres, HTTPS ALB, S3 `objects/*`. DB hostname is an **SSM parameter**, not a baked task-definition env var.

## Budget trade-offs ($150/mo cap, us-east-1 list)

1. **No NAT gateway.** App/db route tables have no `0.0.0.0/0`. Saves ~$33–37 idle. **Hard constraint:** tasks cannot reach the public internet. No npm/public.ecr.aws/webhooks from inside the VPC. ECR, Secrets Manager, SSM, logs, and S3 use VPC endpoints in both app AZs.
2. **Single-AZ `db.t4g.micro`.** AZ loss = full outage until restore. Multi-AZ would ~2× the instance (~+$12) and spend headroom already used by dual-AZ interface endpoints (~$73 for 5 endpoints × 2 AZ).
3. **On-demand Fargate only (no Spot).** Two 0.25 vCPU / 0.5 GB tasks ≈ $18. Spot would save ~$6 and re-introduce PENDING holes the last design had to paper over with capacity providers.

Idle envelope ~$120–135: endpoints ~$73, ALB+$IPv4 ~$24, RDS ~$12, Fargate ~$18, leftovers (logs, secrets, zone, S3, lock table). Headroom is LCUs, PrivateLink GB, and a third task if CPU hits 70%.

## 0. Configure first

| Need | Why |
|---|---|
| AWS credentials in the environment | Nothing secret belongs in tfvars |
| Route53 **public** zone + `domain_name` in that zone | ACM DNS validation. Wrong zone → apply hangs on `aws_acm_certificate_validation` |
| `alert_email` | SNS stays Pending until you confirm |
| Docker on a laptop with internet | Tasks have no NAT; you push ECR from outside the VPC |
| Terraform >= 1.6 | Formatted with 1.9.8 |

```bash
aws sts get-caller-identity
```

Stop if the caller is wrong. This tree was `fmt` + `validate`d. `plan` against a real account was not run from this environment when credentials were missing.

## 1. Remote state, then the environment

Bootstrap keeps **local** state on purpose. An S3 backend cannot create itself.

```bash
terraform -chdir=bootstrap init
terraform -chdir=bootstrap apply
terraform -chdir=bootstrap output -raw backend_hcl > backend.hcl
cp terraform.tfvars.example terraform.tfvars
# set domain_name, hosted_zone_id, alert_email
terraform init -backend-config=backend.hcl
terraform plan -out=live.tfplan
terraform apply live.tfplan
```

Default `desired_count = 0` so the first apply can finish before `:pending` exists in ECR.

## 2. Push the image, then scale in

```bash
chmod +x scripts/*.sh
./scripts/push-api.sh v1
```

In `terraform.tfvars`:

```hcl
container_image = "<ecr_url>:v1"
desired_count   = 2
```

`terraform apply` again. Tasks pull **only** this repo via PrivateLink. The repository is tag-immutable; never retag `v1`.

## 3. Destroy

1. Set `deletion_protection = false` on the DB and apply, or destroy will fail.
2. `skip_final_snapshot` is already false → AWS writes `keel-live-pg-final`.
3. `terraform destroy`
4. Destroy bootstrap last. That deletes state.

## 4. Request path

Internet → ALB (public subnets, :443) → SG peer ALB↔ECS → Fargate in **app** subnets → SG peer ECS↔RDS → Postgres in **db** subnets.

`/readyz` opens a TCP socket to `DB_HOST` (injected from SSM `/keel-live/db-endpoint`). If Postgres is gone it returns 503 and the ALB alarm fires.

Container UID is `1000:1000` in the task definition (precondition + root variable validation). Dockerfile `USER app` is defense in depth, not the control. `privileged` / `readonlyRootFilesystem` / dropped caps do **not** change UID.

## 5. RDS AZ failure

| | |
|---|---|
| Snapshot RPO | **up to 24h** (`backup_window` 06:00–07:00 UTC) |
| PITR RPO | **~5 min** if WAL is still available |
| RTO | **Quote 90 minutes** to a new engineer: ~3 min ALB alarm + human delay + 15–30 min restore of 20 GB gp3 + SSM write + ECS drain. Do not advertise 20–40 min; that assumes someone is already at the keyboard. Grows with data size. |

**Do not** set `snapshot_identifier` on `aws_db_instance.this` (ForceNew). **Do not** `jq` a new task definition to change `DB_HOST`.

```bash
./scripts/restore-db.sh keel-live-pg keel-live-pg-restored
```

That restores a **new** identifier, `ssm put-parameter` overwrites `/keel-live/db-endpoint`, then `ecs update-service --force-new-deployment`. The SSM resource ignores `value` drift so a later apply does not clobber the restored host. After the failed AZ returns: `terraform state rm` the old instance, `terraform import` the restored one, then align `identifier` in a planned change.

`deletion_protection = true` does not change restore time. It only stops a mistaken apply from deleting the dead instance mid-incident.

`manage_master_user_password` snapshots keep the same secret ARN. Do not enable rotation mid-incident.

## 6. Failure modes

| Event | What happens |
|---|---|
| ECS in either app AZ | Endpoints ENIs sit in both app subnets |
| ECR / Secrets / SSM unreachable | EventBridge `CannotPullContainerError` / `ResourceInitializationError` → SNS. ALB stays green until running tasks die |
| RDS AZ loss | `/readyz` 503 → `alb-no-ready` alarm → restore script |
| ACM pending | HTTPS listener is not created (`certificate_validation` waits). PENDING ACM → `UnsupportedCertificate` |
| CPU > 70% | Autoscaling 2–3 on-demand tasks |
| Non-AWS egress | Fails. There is no NAT. This is a product constraint, not a bug |

## 7. Validation actually run

- `terraform fmt -recursive`
- `terraform -chdir=bootstrap init -backend=false && validate`
- `terraform init -backend=false && validate`
- `terraform plan` against a real account: **not run** (no credentials in this environment)
