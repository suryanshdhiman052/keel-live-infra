#!/usr/bin/env bash
# Restore RDS to a NEW identifier, then retarget ECS via SSM (no task-def surgery).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGION="${AWS_REGION:-us-east-1}"
OLD_ID="${1:-keel-live-pg}"
NEW_ID="${2:-keel-live-pg-restored}"
PARAM="$(terraform -chdir="$ROOT" output -raw db_endpoint_parameter)"
CLUSTER="$(terraform -chdir="$ROOT" output -raw cluster_name)"
SERVICE="$(terraform -chdir="$ROOT" output -raw service_name)"

SNAP=$(aws rds describe-db-snapshots --region "$REGION" \
  --db-instance-identifier "$OLD_ID" --snapshot-type automated \
  --query 'sort_by(DBSnapshots[?Status==`available`],&SnapshotCreateTime)[-1].DBSnapshotIdentifier' \
  --output text)
SG=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$OLD_ID" \
  --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' --output text)
SUBNET=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$OLD_ID" \
  --query 'DBInstances[0].DBSubnetGroup.DBSubnetGroupName' --output text)

aws rds restore-db-instance-from-db-snapshot --region "$REGION" \
  --db-instance-identifier "$NEW_ID" \
  --db-snapshot-identifier "$SNAP" \
  --db-instance-class db.t4g.micro \
  --db-subnet-group-name "$SUBNET" \
  --vpc-security-group-ids "$SG" \
  --no-multi-az --no-publicly-accessible --port 5432 --storage-type gp3

aws rds wait db-instance-available --region "$REGION" --db-instance-identifier "$NEW_ID"
NEW_HOST=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$NEW_ID" \
  --query 'DBInstances[0].Endpoint.Address' --output text)

aws ssm put-parameter --region "$REGION" --name "$PARAM" --type String --value "$NEW_HOST" --overwrite
aws ecs update-service --region "$REGION" --cluster "$CLUSTER" --service "$SERVICE" --force-new-deployment
echo "Restored $NEW_ID. SSM $PARAM=$NEW_HOST. ECS redeploying."
echo "Quote RTO 90 minutes (alarm + human + 15-30 min restore + drain). Snapshot RPO up to 24h."
