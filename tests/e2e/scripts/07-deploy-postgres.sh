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

# Note: Barman Cloud Plugin is optional for basic backup functionality
# CloudNativePG has built-in backup support that works without it
# The plugin provides additional features but is not required for E2E tests

echo ""
echo "✓ PostgreSQL operators deployed successfully"
echo ""
echo "Checking operator readiness..."
kubectl get deployment -n cnpg-system
echo ""
echo "✓ CloudNativePG is ready for cluster creation"
