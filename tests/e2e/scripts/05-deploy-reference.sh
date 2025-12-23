#!/bin/bash
set -euo pipefail

SCENARIO="${1}"
INCLUDE_S3="${2}"
CLUSTER_NAME="e2e-${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
REFERENCE_DIR="${PROJECT_ROOT}/examples/${SCENARIO}"

# Use scenario-specific kubeconfig
export KUBECONFIG="${SCRIPT_DIR}/.kubeconfig-${SCENARIO}"

if [[ ! -f "$KUBECONFIG" ]]; then
  echo "Error: Kubeconfig not found: $KUBECONFIG"
  echo "Did you run 00-setup-kind.sh first?"
  exit 1
fi

echo "Creating test-app namespace..."
kubectl create namespace test-app 2>/dev/null || true

echo "Creating secrets..."
if [ "$INCLUDE_S3" = "true" ]; then
  kubectl create secret generic rust-service-secrets \
    -n test-app \
    --from-literal=redis-url=redis://redis.services.svc.cluster.local:6379 \
    --from-literal=aws-access-key-id=minioadmin \
    --from-literal=aws-secret-access-key=minioadmin \
    --dry-run=client -o yaml | kubectl apply -f -
else
  kubectl create secret generic rust-service-secrets \
    -n test-app \
    --from-literal=redis-url=redis://redis.services.svc.cluster.local:6379 \
    --dry-run=client -o yaml | kubectl apply -f -
fi

echo "Building Docker image from reference implementation..."
cd "$REFERENCE_DIR"
docker build -t "rust-service-${SCENARIO}:e2e" .

echo "Loading image into Kind cluster..."
kind load docker-image "rust-service-${SCENARIO}:e2e" --name "${CLUSTER_NAME}"

echo "Deploying via kubectl (simulating Flux)..."
# Apply the overlay directly with image override
kubectl apply -k "${REFERENCE_DIR}/deploy/overlays/dev" -n test-app

# Patch the image to use our e2e built image
kubectl patch ksvc rust-service -n test-app --type='json' \
  -p="[{\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/image\", \"value\": \"rust-service-${SCENARIO}:e2e\"}]"

cd "${PROJECT_ROOT}"

echo "Waiting for Knative Service to be ready..."
kubectl wait --for=condition=Ready ksvc/rust-service \
  -n test-app \
  --timeout=5m

echo "✓ Reference implementation deployed"
