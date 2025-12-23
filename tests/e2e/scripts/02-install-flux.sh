#!/bin/bash
set -euo pipefail

echo "Verifying Flux CD is installed..."

# Check if Flux is already installed on the cluster
if ! kubectl get namespace flux-system &>/dev/null; then
  echo "Error: Flux CD is not installed on this cluster"
  echo "Please install Flux CD first or use a cluster with Flux installed"
  exit 1
fi

echo "Waiting for Flux controllers to be ready..."
kubectl wait --for=condition=Ready pods \
  -n flux-system \
  -l app=source-controller \
  --timeout=2m || {
  echo "Warning: source-controller may not be ready yet, continuing..."
}

kubectl wait --for=condition=Ready pods \
  -n flux-system \
  -l app=kustomize-controller \
  --timeout=2m || {
  echo "Warning: kustomize-controller may not be ready yet, continuing..."
}

echo "✓ Flux CD is available"
