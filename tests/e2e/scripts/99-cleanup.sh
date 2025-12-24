#!/bin/bash
set -euo pipefail

SCENARIO="${1}"
CLUSTER_NAME="e2e-${SCENARIO}"
REGISTRY_NAME="kind-registry-${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_FILE="${SCRIPT_DIR}/.kubeconfig-${SCENARIO}"

echo "Cleaning up local registry: ${REGISTRY_NAME}..."
docker stop "${REGISTRY_NAME}" 2>/dev/null || true
docker rm "${REGISTRY_NAME}" 2>/dev/null || true

echo "Cleaning up Kind cluster: ${CLUSTER_NAME}..."
kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null || true

# Remove kubeconfig file
rm -f "$KUBECONFIG_FILE"

# Remove generated template directory marker and files
GENERATED_DIR_FILE="${SCRIPT_DIR}/.generated-dir-${SCENARIO}"
if [ -f "$GENERATED_DIR_FILE" ]; then
  GENERATED_DIR=$(cat "$GENERATED_DIR_FILE")
  echo "Cleaning up generated template: ${GENERATED_DIR}..."
  rm -rf "$GENERATED_DIR" 2>/dev/null || true
  rm -f "$GENERATED_DIR_FILE"
fi

echo "✓ Cleanup complete"
