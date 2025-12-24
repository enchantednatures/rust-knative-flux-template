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

echo "Verifying infrastructure is ready..."
# Check Redis is accessible with retries
MAX_RETRIES=5
RETRY_COUNT=0
REDIS_ACCESSIBLE=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  echo "Testing Redis connectivity (attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)..."
  
  REDIS_TEST_OUTPUT=$(kubectl run redis-test-$RETRY_COUNT --rm -i --restart=Never --image=redis:7-alpine -n test-app --command -- \
    redis-cli -h redis.services.svc.cluster.local ping 2>&1 || true)
  
  if echo "$REDIS_TEST_OUTPUT" | grep -q PONG; then
    REDIS_ACCESSIBLE=true
    break
  fi
  
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
    echo "Redis not accessible yet, waiting 5 seconds before retry..."
    sleep 5
  fi
done

if [ "$REDIS_ACCESSIBLE" = false ]; then
  echo "❌ Redis is not accessible from test-app namespace after $MAX_RETRIES attempts"
  echo "Last test output: $REDIS_TEST_OUTPUT"
  echo ""
  echo "Checking Redis status:"
  kubectl get pods -n services -l app=redis
  echo ""
  echo "Checking Redis service:"
  kubectl get svc -n services redis
  echo ""
  echo "Testing DNS resolution:"
  kubectl run dns-test --rm -i --restart=Never --image=busybox:latest -n test-app -- \
    nslookup redis.services.svc.cluster.local || true
  exit 1
fi
echo "✓ Redis is accessible"

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
# Save original kustomization.yaml
KUSTOMIZATION_FILE="${REFERENCE_DIR}/deploy/overlays/dev/kustomization.yaml"
cp "$KUSTOMIZATION_FILE" "${KUSTOMIZATION_FILE}.backup"

# Override namespace in kustomization to use test-app instead of example-app
cd "${REFERENCE_DIR}/deploy/overlays/dev"
kustomize edit set namespace test-app

# Build the kustomization, override service endpoints for E2E environment, and apply
kubectl kustomize "${REFERENCE_DIR}/deploy/overlays/dev" | \
  sed 's|http://minio:9000|http://minio.services.svc.cluster.local:9000|g' | \
  kubectl apply -f -

# Restore original kustomization.yaml
mv "${KUSTOMIZATION_FILE}.backup" "$KUSTOMIZATION_FILE"

cd "${PROJECT_ROOT}"

# Patch the image to use our e2e built image
kubectl patch ksvc rust-service -n test-app --type='json' \
  -p="[{\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/image\", \"value\": \"rust-service-${SCENARIO}:e2e\"}]"

echo "Waiting for Knative Service to be ready..."
if ! kubectl wait --for=condition=Ready ksvc/rust-service \
  -n test-app \
  --timeout=5m; then
  
  echo ""
  echo "❌ Knative Service failed to become ready. Diagnostic information:"
  echo ""
  echo "=== Service Status ==="
  kubectl get ksvc rust-service -n test-app -o yaml
  echo ""
  echo "=== Pods ==="
  kubectl get pods -n test-app
  echo ""
  echo "=== Pod Logs ==="
  kubectl logs -n test-app -l serving.knative.dev/service=rust-service --tail=100 || echo "No logs available yet"
  echo ""
  echo "=== Events ==="
  kubectl get events -n test-app --sort-by='.lastTimestamp' | tail -20
  
  exit 1
fi

echo "✓ Reference implementation deployed"
