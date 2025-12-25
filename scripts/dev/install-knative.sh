#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
KUBECONFIG_PATH="${PROJECT_ROOT}/.kubeconfig-dev"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

if [[ ! -f "$KUBECONFIG_PATH" ]]; then
  echo -e "${RED}✗ Error: Kubeconfig not found at ${KUBECONFIG_PATH}${NC}"
  echo "Run 'make dev-cluster' first"
  exit 1
fi

export KUBECONFIG="$KUBECONFIG_PATH"

KNATIVE_VERSION="1.20.0"

echo "Installing Knative Serving v${KNATIVE_VERSION}..."
echo ""

echo -e "${YELLOW}→${NC} Installing CRDs..."
kubectl apply -f "https://github.com/knative/serving/releases/download/knative-v${KNATIVE_VERSION}/serving-crds.yaml" || {
  echo -e "${RED}✗ Error: Failed to install Knative CRDs${NC}"
  exit 1
}

echo -e "${YELLOW}→${NC} Installing core components..."
kubectl apply -f "https://github.com/knative/serving/releases/download/knative-v${KNATIVE_VERSION}/serving-core.yaml" || {
  echo -e "${RED}✗ Error: Failed to install Knative core${NC}"
  exit 1
}

echo -e "${YELLOW}→${NC} Installing Kourier networking..."
kubectl apply -f "https://github.com/knative/net-kourier/releases/download/knative-v${KNATIVE_VERSION}/kourier.yaml" || {
  echo -e "${RED}✗ Error: Failed to install Kourier${NC}"
  exit 1
}

echo -e "${YELLOW}→${NC} Configuring Knative to use Kourier..."
kubectl patch configmap/config-network \
  -n knative-serving \
  --type merge \
  -p '{"data":{"ingress-class":"kourier.ingress.networking.knative.dev"}}' || {
  echo -e "${RED}✗ Error: Failed to patch config-network${NC}"
  exit 1
}

echo -e "${YELLOW}→${NC} Configuring magic DNS (127.0.0.1.sslip.io)..."
kubectl patch configmap/config-domain \
  -n knative-serving \
  --type merge \
  -p '{"data":{"127.0.0.1.sslip.io":""}}' || {
  echo -e "${RED}✗ Error: Failed to patch config-domain${NC}"
  exit 1
}

echo -e "${YELLOW}→${NC} Configuring registry skip for local development..."
kubectl patch configmap/config-deployment \
  -n knative-serving \
  --type merge \
  -p '{"data":{"registries-skipping-tag-resolving":"localhost:5001"}}' || {
  echo -e "${RED}✗ Error: Failed to patch config-deployment${NC}"
  exit 1
}

echo -e "${YELLOW}→${NC} Waiting for Knative to be ready (this may take a few minutes)..."
if ! kubectl wait --for=condition=Ready pods --all -n knative-serving --timeout=5m; then
  echo -e "${RED}✗ Error: Knative failed to become ready${NC}"
  echo ""
  echo "Pod status:"
  kubectl get pods -n knative-serving
  echo ""
  echo "Recent events:"
  kubectl get events -n knative-serving --sort-by='.lastTimestamp' | tail -20
  exit 1
fi

echo ""
echo -e "${GREEN}✓ Knative Serving v${KNATIVE_VERSION} installed successfully${NC}"
echo ""
