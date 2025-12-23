#!/bin/bash
set -euo pipefail

SCENARIO="${1}"
CLUSTER_NAME="e2e-${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_FILE="${SCRIPT_DIR}/.kubeconfig-${SCENARIO}"

echo "Cleaning up Kind cluster: ${CLUSTER_NAME}..."
kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null || true

# Remove kubeconfig file
rm -f "$KUBECONFIG_FILE"

echo "✓ Cleanup complete"
