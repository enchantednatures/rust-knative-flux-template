#!/bin/bash
set -euo pipefail

SCENARIO="${1:-with-s3}"
NAMESPACE="e2e-test-${SCENARIO}"

echo "Setting up test namespace: ${NAMESPACE}..."

# Delete namespace if it exists (cleanup from previous runs)
kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true --wait=true || true

# Wait a moment for namespace deletion to complete
sleep 5

# Create fresh namespace for this test run
kubectl create namespace "${NAMESPACE}"

# Label namespace for identification
kubectl label namespace "${NAMESPACE}" \
  test-scenario="${SCENARIO}" \
  test-type=e2e \
  app=rust-knative-template

echo "Verifying cluster access..."
kubectl cluster-info
kubectl get namespace "${NAMESPACE}"

echo "✓ Test namespace ready: ${NAMESPACE}"
