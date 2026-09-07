#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGION="${AWS_REGION:-us-east-1}"
TAG="${1:-v1}"
REPO="$(terraform -chdir="$ROOT" output -raw ecr_repository_url)"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${REPO%%/*}"
docker build -t "$REPO:$TAG" "$ROOT/app"
docker push "$REPO:$TAG"
echo "Set container_image = \"$REPO:$TAG\" and desired_count = 2, then apply."
