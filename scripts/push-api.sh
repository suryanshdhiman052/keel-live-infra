#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGION="${AWS_REGION:-us-east-1}"
TAG="${1:-v1}"
REPO="$(terraform -chdir="$ROOT" output -raw registry)"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${REPO%%/*}"
docker build -t "$REPO:$TAG" "$ROOT/app"
docker push "$REPO:$TAG"
echo "Put image_uri = \"$REPO:$TAG\" and replica_min = 2 in terraform.tfvars, then apply."
