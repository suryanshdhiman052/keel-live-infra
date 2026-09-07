#!/usr/bin/env bash
# New RDS identifier, then flip SSM. Do not edit the task family.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGION="${AWS_REGION:-us-east-1}"
OLD="${1:-keel-shop-pg}"
NEW="${2:-keel-shop-pg-rewind}"
PARAM="$(terraform -chdir="$ROOT" output -raw pg_host_param)"
CLUSTER="$(terraform -chdir="$ROOT" output -raw cluster)"
SERVICE="$(terraform -chdir="$ROOT" output -raw service)"

SNAP=$(aws rds describe-db-snapshots --region "$REGION" \
  --db-instance-identifier "$OLD" --snapshot-type automated \
  --query 'sort_by(DBSnapshots[?Status==`available`],&SnapshotCreateTime)[-1].DBSnapshotIdentifier' \
  --output text)
SG=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$OLD" \
  --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' --output text)
SUBNET=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$OLD" \
  --query 'DBInstances[0].DBSubnetGroup.DBSubnetGroupName' --output text)

aws rds restore-db-instance-from-db-snapshot --region "$REGION" \
  --db-instance-identifier "$NEW" \
  --db-snapshot-identifier "$SNAP" \
  --db-instance-class db.t4g.micro \
  --db-subnet-group-name "$SUBNET" \
  --vpc-security-group-ids "$SG" \
  --no-multi-az --no-publicly-accessible --port 5432 --storage-type gp3

aws rds wait db-instance-available --region "$REGION" --db-instance-identifier "$NEW"
HOST=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$NEW" \
  --query 'DBInstances[0].Endpoint.Address' --output text)

aws ssm put-parameter --region "$REGION" --name "$PARAM" --type String --value "$HOST" --overwrite
aws ecs update-service --region "$REGION" --cluster "$CLUSTER" --service "$SERVICE" --force-new-deployment
echo "Rewound to $NEW. $PARAM now $HOST. Tasks recycling."
echo "Tell a new on-call 90 minutes, not 20. Snapshot RPO can be a full day."
