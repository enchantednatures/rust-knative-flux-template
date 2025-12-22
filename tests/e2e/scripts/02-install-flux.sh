#!/bin/bash
set -euo pipefail

echo "Installing Flux CLI..."
curl -s https://fluxcd.io/install.sh | sudo bash

echo "Installing Flux (minimal: source + kustomize controllers)..."
flux install \
  --components=source-controller,kustomize-controller \
  --network-policy=false \
  --timeout=5m

echo "Waiting for Flux controllers..."
kubectl wait --for=condition=Ready pods \
  -n flux-system \
  -l app=source-controller \
  --timeout=3m

kubectl wait --for=condition=Ready pods \
  -n flux-system \
  -l app=kustomize-controller \
  --timeout=3m

echo "✓ Flux CD installed"
