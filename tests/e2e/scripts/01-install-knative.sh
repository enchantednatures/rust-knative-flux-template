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

KNATIVE_VERSION="1.16.0"

echo "Installing Knative Serving CRDs..."
kubectl apply -f "https://github.com/knative/serving/releases/download/knative-v${KNATIVE_VERSION}/serving-crds.yaml"

echo "Installing Knative Serving core..."
kubectl apply -f "https://github.com/knative/serving/releases/download/knative-v${KNATIVE_VERSION}/serving-core.yaml"

echo "Installing Kourier (networking layer)..."
kubectl apply -f "https://github.com/knative/net-kourier/releases/download/knative-v${KNATIVE_VERSION}/kourier.yaml"

echo "Configuring Knative to use Kourier..."
kubectl patch configmap/config-network \
  -n knative-serving \
  --type merge \
  -p '{"data":{"ingress-class":"kourier.ingress.networking.knative.dev"}}'

echo "Configuring magic DNS (sslip.io)..."
kubectl patch configmap/config-domain \
  -n knative-serving \
  --type merge \
  -p '{"data":{"127.0.0.1.sslip.io":""}}'

echo "Configuring Knative to skip digest resolution for local registry..."
kubectl patch configmap/config-deployment \
  -n knative-serving \
  --type merge \
  -p '{"data":{"registries-skipping-tag-resolving":"kind-registry-no-s3:5000,kind-registry-with-s3:5000"}}'

echo "Waiting for Knative to be ready..."
kubectl wait --for=condition=Ready pods --all -n knative-serving --timeout=5m

echo "✓ Knative Serving installed"
