#!/usr/bin/env bash
# setup.sh — build, load into the local cluster, provision with Terraform,
# deploy with Helm. Any failed step aborts with a non-zero exit; safe to re-run.
set -euo pipefail

IMAGE_TAG="${IMAGE_TAG:-1.0.0}"
IMAGE="skybyte/app:${IMAGE_TAG}"
NAMESPACE="devops-challenge"
RELEASE="skybyte-app"

echo "==> Building image ${IMAGE}"
docker build -t "${IMAGE}" .

# Load into the local cluster so pullPolicy=IfNotPresent finds the image.
if command -v kind >/dev/null 2>&1 && [ "$(kind get clusters 2>/dev/null | wc -l)" -gt 0 ]; then
  echo "==> Loading ${IMAGE} into kind"
  kind load docker-image "${IMAGE}"
elif command -v minikube >/dev/null 2>&1 && minikube status >/dev/null 2>&1; then
  echo "==> Loading ${IMAGE} into minikube"
  minikube image load "${IMAGE}"
else
  echo "!! No kind/minikube cluster detected; assuming the image is reachable" >&2
fi

echo "==> Applying Terraform (namespace, quota, secret)"
# Local-only fallback value so the script runs hands-off; real environments
# MUST export TF_VAR_api_token instead. Terraform owns the secret (no default
# in variables.tf) — plaintext-in-state tradeoff documented in DECISIONS.md.
export TF_VAR_api_token="${TF_VAR_api_token:-local-dev-only-not-a-real-secret}"
( cd terraform && terraform init -input=false && terraform apply -auto-approve )

echo "==> Installing/upgrading Helm release ${RELEASE}"
# --wait: a pod rejected by the ResourceQuota must fail the script, not linger.
helm upgrade --install "${RELEASE}" helm/skybyte-app \
  --namespace "${NAMESPACE}" \
  --set image.tag="${IMAGE_TAG}" \
  --wait --timeout 2m

echo "==> SUCCESS: ${RELEASE} deployed to namespace ${NAMESPACE} (tag ${IMAGE_TAG})"
