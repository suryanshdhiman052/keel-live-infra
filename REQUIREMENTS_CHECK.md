# Requirements check (keel live)

| # | Requirement | How this stack meets it |
|---|---|---|
| 1 | ≥3 modules | `networking`, `compute`, `database` |
| 2 | ECS non-root + least privilege | UID `1000:1000` hardcoded + validation + task-definition precondition; Dockerfile `USER app`; exec/task roles scoped |
| 3 | RDS private | `publicly_accessible = false`, db subnets, SG 5432 from ECS only |
| 4 | Remote state S3 + DynamoDB lock | `bootstrap/` + root `backend "s3" {}` + `LockID` |
| 5 | ≤$150 trade-off + real consequence | **No NAT** + single-AZ `db.t4g.micro` + on-demand only; RTO **90 min** / snapshot RPO ≤24h |
| 6 | GitHub link | https://github.com/suryanshdhiman052/keel-live-infra |
| 7 | Runbook | `RUNBOOK.md` |

## Deliberate differences vs prior attempts

- SSM parameter for `DB_HOST` (restore = put-parameter, not task-def jq / Cloud Map / private zone)
- On-demand + CPU autoscaling 2–3 (no Spot mix)
- Health path `/readyz`, S3 prefix `objects/`, CIDR `10.81.0.0/16`, name `keel`
- No `enable_egress_nat` flag — private tables have no `0.0.0.0/0`
- Interface endpoint set includes `ssm`
- 20k packer never drops subnets / ECR / SNS / SG peers
