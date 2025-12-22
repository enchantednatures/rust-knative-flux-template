#!/bin/bash
set -euo pipefail

SCENARIO="${1}"
CLUSTER_NAME="e2e-${SCENARIO}"

echo "Cleaning up Kind cluster: ${CLUSTER_NAME}..."
kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null || true

echo "✓ Cleanup complete"
