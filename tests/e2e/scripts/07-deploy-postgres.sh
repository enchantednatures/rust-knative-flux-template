#!/bin/bash
set -euo pipefail

# Get scenario from environment (set by workflow)
SCENARIO="${SCENARIO:-}"
if [[ -z "$SCENARIO" ]]; then
  echo "Error: SCENARIO environment variable not set"
  exit 1
fi

# Use scenario-specific kubeconfig
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${SCRIPT_DIR}/.kubeconfig-${SCENARIO}"

if [[ ! -f "$KUBECONFIG" ]]; then
  echo "Error: Kubeconfig not found: $KUBECONFIG"
  echo "Did you run 00-setup-kind.sh first?"
  exit 1
fi

echo "=== Deploying PostgreSQL for E2E Tests ==="
echo ""

# Install CloudNativePG operator
echo "Installing CloudNativePG operator..."
kubectl apply --server-side -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.28/releases/cnpg-1.28.0.yaml

echo "Waiting for CloudNativePG operator to be ready..."
if ! kubectl wait --for=condition=Available deployment/cnpg-controller-manager \
  -n cnpg-system --timeout=3m 2>/dev/null; then
  echo "Error: CloudNativePG operator failed to become ready"
  kubectl get deployment -n cnpg-system
  kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg --tail=50 || true
  exit 1
fi

# The template's ObjectStore/ScheduledBackup CRs are plugin-based (method:
# plugin), not the deprecated built-in backup.barmanObjectStore.
echo ""
echo "Installing Barman Cloud Plugin..."
kubectl apply --server-side \
  -f https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.11.0/manifest.yaml

echo ""
echo "Waiting for Barman Cloud Plugin to be ready..."
if ! kubectl wait --for=condition=Available deployment/plugin-barman-cloud \
  -n cnpg-system --timeout=5m 2>/dev/null; then
  echo "Warning: plugin-barman-cloud did not become Available in 5m (backups will fail; basic cluster tests can still run)"
  kubectl get deployment -n cnpg-system || true
fi

# Create the minio backup bucket used by the e2e ObjectStore when MinIO is
# present in the local dev cluster (barman does not create buckets).
if kubectl get svc minio -n minio &>/dev/null; then
  echo "Ensuring e2e backup bucket exists in MinIO..."
  kubectl -n minio run mc-init --rm -i --image=minio/mc:latest --restart=Never \
    --env=MC_HOST_local="http://minioadmin:minioadmin@minio.minio.svc.cluster.local:9000" \
    -- /bin/sh -c 'until mc alias ls local >/dev/null 2>&1; do sleep 2; done; mc mb local/example-app-postgres-backups --ignore-existing' \
    >/dev/null 2>&1 || echo "Warning: could not create backup bucket (continuing)"
fi

echo ""
echo "✓ PostgreSQL operators deployed successfully"
echo ""
echo "Checking operator readiness..."
kubectl get deployment -n cnpg-system
echo ""
echo "✓ CloudNativePG is ready for cluster creation"
