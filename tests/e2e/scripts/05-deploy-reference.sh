#!/bin/bash
set -euo pipefail

SCENARIO="${1}"
INCLUDE_S3="${2}"
CLUSTER_NAME="e2e-${SCENARIO}"
REFERENCE_DIR="examples/${SCENARIO}"

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

cd ../..

echo "Deploying via kubectl (simulating Flux)..."
# Create a temporary kustomization to patch the image
TEMP_KUSTOMIZATION=$(mktemp -d)
cat > "${TEMP_KUSTOMIZATION}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- ${REFERENCE_DIR}/deploy/overlays/dev
namespace: test-app
images:
- name: ghcr.io/your-org/rust-service
  newName: rust-service-${SCENARIO}
  newTag: e2e
EOF

kubectl apply -k "${TEMP_KUSTOMIZATION}"
rm -rf "${TEMP_KUSTOMIZATION}"

echo "Waiting for Knative Service to be ready..."
kubectl wait --for=condition=Ready ksvc/rust-service \
  -n test-app \
  --timeout=5m

echo "✓ Reference implementation deployed"
