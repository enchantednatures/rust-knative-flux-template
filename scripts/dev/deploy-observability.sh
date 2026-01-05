#!/bin/bash
set -euo pipefail

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
fi

echo "Deploying observability stack (required)..."
echo ""

# Create observability namespace
echo -e "${YELLOW}→${NC} Creating observability namespace..."
kubectl create namespace observability 2>/dev/null || true

# Deploy observability components
echo -e "${YELLOW}→${NC} Deploying Jaeger, Prometheus, and OTel Collector..."
kubectl apply -k deploy/dev/observability || {
  echo -e "${RED}✗ Error: Failed to deploy observability stack${NC}"
  exit 1
}

# Validate Jaeger
echo -e "${YELLOW}→${NC} Waiting for Jaeger to be ready..."
if ! kubectl wait --for=condition=Ready pod -l app=jaeger -n observability --timeout=5m; then
  echo -e "${RED}✗ Error: Jaeger failed to become ready${NC}"
  echo ""
  echo "=== Pod Status ==="
  kubectl get pods -n observability -l app=jaeger
  echo ""
  echo "=== Pod Logs ==="
  kubectl logs -l app=jaeger -n observability --tail=100 --all-containers=true 2>&1 || true
  echo ""
  echo "=== Pod Descriptions ==="
  kubectl describe pods -l app=jaeger -n observability | head -100
  echo ""
  echo "=== Events ==="
  kubectl get events -n observability --sort-by='.lastTimestamp' | tail -20
  exit 1
fi

# Validate OTel Collector - more lenient timeout
echo -e "${YELLOW}→${NC} Waiting for OpenTelemetry Collector to be ready..."
if ! kubectl wait --for=condition=Ready pod -l app=otel-collector -n observability --timeout=10m; then
  echo -e "${RED}⚠ Warning: OTel Collector did not reach Ready state, but checking if it's running...${NC}"
  
  # Check if pod is actually running despite not being "Ready"
  OTEL_STATUS=$(kubectl get pods -n observability -l app=otel-collector -o jsonpath='{.items[0].status.phase}')
  if [[ "$OTEL_STATUS" == "Running" ]]; then
    echo -e "${YELLOW}⚠ OTel Collector is Running (no health checks configured)${NC}"
  else
    echo ""
    echo "=== Pod Status ==="
    kubectl get pods -n observability -l app=otel-collector
    echo ""
    echo "=== Pod Logs ==="
    kubectl logs -l app=otel-collector -n observability --tail=100 --all-containers=true 2>&1 || true
    echo ""
    echo "=== Pod Descriptions ==="
    kubectl describe pods -l app=otel-collector -n observability | head -100
    echo ""
    echo "=== Events ==="
    kubectl get events -n observability --sort-by='.lastTimestamp' | tail -20
    exit 1
  fi
fi

# Validate Prometheus
echo -e "${YELLOW}→${NC} Waiting for Prometheus to be ready..."
if ! kubectl wait --for=condition=Ready pod -l app=prometheus -n observability --timeout=5m; then
  echo -e "${RED}✗ Error: Prometheus failed to become ready${NC}"
  echo ""
  echo "=== Pod Status ==="
  kubectl get pods -n observability -l app=prometheus
  echo ""
  echo "=== Pod Logs ==="
  kubectl logs -l app=prometheus -n observability --tail=100 --all-containers=true 2>&1 || true
  echo ""
  echo "=== Pod Descriptions ==="
  kubectl describe pods -l app=prometheus -n observability | head -100
  echo ""
  echo "=== Events ==="
  kubectl get events -n observability --sort-by='.lastTimestamp' | tail -20
  exit 1
fi

echo ""
echo -e "${GREEN}✓ Observability stack deployed successfully${NC}"
kubectl get pods -n observability
echo ""
