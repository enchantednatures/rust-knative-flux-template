#!/bin/bash
set -euo pipefail

# Get scenario from calling script's environment or infer from current test
SCENARIO="${SCENARIO:-${1:-}}"
if [[ -z "$SCENARIO" ]]; then
  echo "Error: SCENARIO not set. This script should be called from the workflow."
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

echo "Checking Flux CLI..."
if ! command -v flux &> /dev/null; then
  echo "Installing Flux CLI..."
  # Install to user local bin without sudo
  curl -s https://fluxcd.io/install.sh | bash -s -- --bindir=$HOME/.local/bin
  export PATH="$HOME/.local/bin:$PATH"
else
  echo "Flux CLI already installed: $(flux --version)"
fi

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
