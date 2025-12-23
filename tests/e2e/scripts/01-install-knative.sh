#!/bin/bash
set -euo pipefail

echo "Verifying Knative Serving is installed..."

# Check if Knative is already installed on the cluster
if ! kubectl get namespace knative-serving &>/dev/null; then
  echo "Error: Knative Serving is not installed on this cluster"
  echo "Please install Knative Serving first or use a cluster with Knative installed"
  exit 1
fi

echo "Waiting for Knative to be ready..."
kubectl wait --for=condition=Ready pods --all -n knative-serving --timeout=2m || {
  echo "Warning: Some Knative pods may not be ready yet, continuing..."
}

echo "✓ Knative Serving is available"
