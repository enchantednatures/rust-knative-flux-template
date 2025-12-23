#!/bin/bash
set -euo pipefail

SCENARIO="${1}"
NAMESPACE="e2e-test-${SCENARIO}"

echo "Cleaning up test namespace: ${NAMESPACE}..."
kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true --wait=false || true

echo "✓ Cleanup initiated (namespace will be deleted asynchronously)"
