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

KNATIVE_VERSION="1.20.1"

echo "Installing Knative Eventing Kafka v${KNATIVE_VERSION}..."
echo ""

echo -e "${YELLOW}→${NC} Installing Knative Eventing core..."
kubectl apply -f "https://github.com/knative/eventing/releases/download/knative-v${KNATIVE_VERSION}/eventing-crds.yaml" || {
  echo -e "${RED}✗ Error: Failed to install Eventing CRDs${NC}"
  exit 1
}

kubectl apply -f "https://github.com/knative/eventing/releases/download/knative-v${KNATIVE_VERSION}/eventing-core.yaml" || {
  echo -e "${RED}✗ Error: Failed to install Eventing core${NC}"
  exit 1
}

echo -e "${YELLOW}→${NC} Installing Kafka event source controller..."
kubectl apply -f "https://github.com/knative-extensions/eventing-kafka-broker/releases/download/knative-v${KNATIVE_VERSION}/eventing-kafka-controller.yaml" || {
  echo -e "${RED}✗ Error: Failed to install Kafka controller${NC}"
  exit 1
}

echo -e "${YELLOW}→${NC} Installing Kafka event source data plane..."
kubectl apply -f "https://github.com/knative-extensions/eventing-kafka-broker/releases/download/knative-v${KNATIVE_VERSION}/eventing-kafka-source.yaml" || {
  echo -e "${RED}✗ Error: Failed to install Kafka source data plane${NC}"
  exit 1
}

echo -e "${YELLOW}→${NC} Waiting for Knative Eventing to be ready..."
if ! kubectl wait --for=condition=Ready pods --all -n knative-eventing --timeout=5m 2>/dev/null; then
  echo -e "${YELLOW}⚠ Warning: Some pods may still be initializing${NC}"
  echo "Pod status:"
  kubectl get pods -n knative-eventing
fi

echo ""
echo -e "${GREEN}✓ Knative Eventing Kafka v${KNATIVE_VERSION} installed successfully${NC}"
echo ""
echo -e "${YELLOW}Documentation:${NC}"
echo "  • Kafka Source: https://knative.dev/docs/eventing/sources/kafka-source/"
echo "  • Eventing: https://knative.dev/docs/eventing/"
echo ""
