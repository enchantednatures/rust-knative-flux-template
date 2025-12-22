#!/bin/bash
set -euo pipefail

SCENARIO="${1:-with-s3}"
CLUSTER_NAME="e2e-${SCENARIO}"

echo "Creating Kind cluster: ${CLUSTER_NAME}..."

kind create cluster \
  --name "${CLUSTER_NAME}" \
  --config tests/e2e/kind-config.yaml \
  --wait 5m

echo "Verifying cluster..."
kubectl cluster-info --context "kind-${CLUSTER_NAME}"
kubectl wait --for=condition=Ready nodes --all --timeout=3m

echo "✓ Kind cluster ready"
