#!/bin/bash
set -euo pipefail

SCENARIO="${1}"
INCLUDE_S3="${2}"
NAMESPACE="e2e-test-${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
REFERENCE_DIR="${PROJECT_ROOT}/examples/${SCENARIO}"
IMAGE_NAME="rust-service-${SCENARIO}:e2e-$(date +%s)"

echo "Building Docker image from reference implementation..."
cd "$REFERENCE_DIR"
docker build -t "${IMAGE_NAME}" .

echo "Creating secrets..."
if [ "$INCLUDE_S3" = "true" ]; then
  kubectl create secret generic rust-service-secrets \
    -n ${NAMESPACE} \
    --from-literal=redis-url=redis://redis.${NAMESPACE}.svc.cluster.local:6379 \
    --from-literal=aws-access-key-id=minioadmin \
    --from-literal=aws-secret-access-key=minioadmin \
    --dry-run=client -o yaml | kubectl apply -f -
else
  kubectl create secret generic rust-service-secrets \
    -n ${NAMESPACE} \
    --from-literal=redis-url=redis://redis.${NAMESPACE}.svc.cluster.local:6379 \
    --dry-run=client -o yaml | kubectl apply -f -
fi

echo "Deploying via kubectl (simulating Flux)..."
# Apply the overlay directly with image override
kubectl apply -k "${REFERENCE_DIR}/deploy/overlays/dev" -n ${NAMESPACE}

# Patch the image to use our e2e built image
kubectl patch ksvc rust-service -n ${NAMESPACE} --type='json' \
  -p="[{\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/image\", \"value\": \"${IMAGE_NAME}\"}]"

cd "${PROJECT_ROOT}"

echo "Waiting for Knative Service to be ready..."
kubectl wait --for=condition=Ready ksvc/rust-service \
  -n ${NAMESPACE} \
  --timeout=5m

echo "✓ Reference implementation deployed"
