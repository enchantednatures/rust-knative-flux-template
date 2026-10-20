#!/bin/bash
set -euo pipefail

# Local-dev only: installs Knative Eventing (core + PingSource CRD) for scheduled
# work. Requires cluster-admin on a throwaway local cluster. This does NOT install
# Kafka controllers or sources -- PingSource only needs Eventing core.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Use existing KUBECONFIG if set, otherwise use local dev config
if [[ -z "${KUBECONFIG:-}" ]]; then
  KUBECONFIG_PATH="${PROJECT_ROOT}/.kubeconfig-dev"
  if [[ ! -f "$KUBECONFIG_PATH" ]]; then
    echo -e "${RED}✗ Error: Kubeconfig not found at ${KUBECONFIG_PATH}${NC}"
    echo "Run 'make dev-cluster' first"
    exit 1
  fi
  export KUBECONFIG="$KUBECONFIG_PATH"
elif [[ ! -f "${KUBECONFIG}" ]]; then
  echo -e "${RED}✗ Error: Kubeconfig not found at ${KUBECONFIG}${NC}"
  echo "Check your KUBECONFIG environment variable"
  exit 1
fi

KNATIVE_VERSION="1.20.0"

echo "Installing Knative Eventing v${KNATIVE_VERSION} (local-dev only)..."
echo -e "${YELLOW}Note:${NC} this requires cluster-admin on a local/dev cluster."
echo ""

echo -e "${YELLOW}→${NC} Installing Eventing CRDs..."
kubectl apply -f "https://github.com/knative/eventing/releases/download/knative-v${KNATIVE_VERSION}/eventing-crds.yaml" || {
  echo -e "${RED}✗ Error: Failed to install Knative Eventing CRDs${NC}"
  exit 1
}

echo -e "${YELLOW}→${NC} Installing Eventing core components..."
kubectl apply -f "https://github.com/knative/eventing/releases/download/knative-v${KNATIVE_VERSION}/eventing-core.yaml" || {
  echo -e "${RED}✗ Error: Failed to install Knative Eventing core${NC}"
  exit 1
}

echo -e "${YELLOW}→${NC} Waiting for PingSource CRD to be established..."
if ! kubectl wait --for=condition=Established crd/pingsources.sources.knative.dev --timeout=2m; then
  echo -e "${RED}✗ Error: PingSource CRD failed to become established${NC}"
  kubectl get crd/pingsources.sources.knative.dev -o yaml || true
  exit 1
fi

# Do NOT wait for pingsource-mt-adapter: it scales from zero when the first
# PingSource is created, so it has no running pods yet.
echo -e "${YELLOW}→${NC} Waiting for Eventing controller and webhook to be available..."
if ! kubectl wait --for=condition=Available deployment/eventing-controller -n knative-eventing --timeout=5m; then
  echo -e "${RED}✗ Error: eventing-controller failed to become available${NC}"
  kubectl get pods -n knative-eventing || true
  exit 1
fi

if ! kubectl wait --for=condition=Available deployment/eventing-webhook -n knative-eventing --timeout=5m; then
  echo -e "${RED}✗ Error: eventing-webhook failed to become available${NC}"
  kubectl get pods -n knative-eventing || true
  exit 1
fi

echo ""
echo -e "${GREEN}✓ Knative Eventing v${KNATIVE_VERSION} installed successfully${NC}"
echo ""
