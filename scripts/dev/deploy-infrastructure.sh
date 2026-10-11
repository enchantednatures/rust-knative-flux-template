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

# kubectl wait errors immediately ("no matching resources found") when a label
# selector matches zero pods, but a freshly applied Deployment may need a
# moment to create its first pod. Wait for a matching pod to exist before
# waiting on its Ready condition.
wait_for_pods() {
  local namespace="$1" selector="$2" timeout="${3:-300}"
  local waited=0
  until [ -n "$(kubectl get pod -l "$selector" -n "$namespace" --no-headers 2>/dev/null)" ]; do
    if [ "$waited" -ge 120 ]; then
      echo "✗ timed out waiting for a pod matching '${selector}' in ${namespace}" >&2
      return 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
  kubectl wait --for=condition=Ready pod -l "$selector" -n "$namespace" --timeout="${timeout}s"
}

echo "Deploying infrastructure services..."
echo ""

# Create infrastructure namespaces
echo -e "${YELLOW}→${NC} Creating infrastructure namespaces..."
kubectl create namespace redis 2>/dev/null || true
kubectl create namespace kafka 2>/dev/null || true
kubectl create namespace rustfs 2>/dev/null || true

# Deploy infrastructure
echo -e "${YELLOW}→${NC} Deploying Redis, Kafka, and RustFS..."
kubectl apply -k deploy/dev/infrastructure || {
  echo -e "${RED}✗ Error: Failed to deploy infrastructure${NC}"
  exit 1
}

echo -e "${YELLOW}→${NC} Waiting for Redis to be ready..."
if ! wait_for_pods redis app=redis 180; then
  echo -e "${RED}✗ Error: Redis failed to become ready${NC}"
  echo ""
  echo "=== Pod Status ==="
  kubectl get pods -n redis -l app=redis
  echo ""
  echo "=== Pod Logs ==="
  kubectl logs -l app=redis -n redis --tail=100 --all-containers=true 2>&1 || true
  echo ""
  echo "=== Pod Descriptions ==="
  kubectl describe pods -l app=redis -n redis | head -100
  echo ""
  echo "=== Events ==="
  kubectl get events -n redis --sort-by='.lastTimestamp' | tail -20
  exit 1
fi

# Check for RustFS in the manifest
if kubectl get statefulset rustfs -n rustfs 2>/dev/null || kubectl get deployment rustfs -n rustfs 2>/dev/null; then
  echo -e "${YELLOW}→${NC} Waiting for RustFS to be ready..."
  if ! wait_for_pods rustfs app=rustfs 300; then
    echo -e "${RED}✗ Error: RustFS failed to become ready${NC}"
    echo ""
    echo "=== Pod Status ==="
    kubectl get pods -n rustfs -l app=rustfs
    echo ""
    echo "=== Pod Logs ==="
    kubectl logs -l app=rustfs -n rustfs --tail=100 --all-containers=true 2>&1 || true
    echo ""
    echo "=== Pod Descriptions ==="
    kubectl describe pods -l app=rustfs -n rustfs | head -100
    echo ""
    echo "=== Events ==="
    kubectl get events -n rustfs --sort-by='.lastTimestamp' | tail -20
    exit 1
  fi
  
  echo -e "${YELLOW}→${NC} Waiting for RustFS bucket initialization..."
  if ! kubectl wait --for=condition=complete job/rustfs-init -n rustfs --timeout=2m 2>/dev/null; then
    echo -e "${YELLOW}⚠${NC} RustFS bucket creation may be pending, checking job..."
    kubectl logs -n rustfs job/rustfs-init 2>/dev/null || true
  fi
fi

# Check for Kafka in the manifest
if kubectl get statefulset kafka -n kafka 2>/dev/null; then
  echo -e "${YELLOW}→${NC} Waiting for Kafka to be ready..."
  if ! wait_for_pods kafka app=kafka 300; then
    echo -e "${RED}✗ Error: Kafka failed to become ready${NC}"
    echo ""
    echo "=== Pod Status ==="
    kubectl get pods -n kafka -l app=kafka
    echo ""
    echo "=== Pod Logs ==="
    kubectl logs -l app=kafka -n kafka --tail=100 --all-containers=true 2>&1 || true
    echo ""
    echo "=== Pod Descriptions ==="
    kubectl describe pods -l app=kafka -n kafka | head -100
    echo ""
    echo "=== Events ==="
    kubectl get events -n kafka --sort-by='.lastTimestamp' | tail -20
    exit 1
  fi
  
  echo -e "${YELLOW}→${NC} Waiting for Kafka topic initialization..."
  if ! kubectl wait --for=condition=complete job/kafka-topic-init -n kafka --timeout=2m 2>/dev/null; then
    echo -e "${YELLOW}⚠${NC} Kafka topic creation may be pending, checking job..."
    kubectl logs -n kafka job/kafka-topic-init 2>/dev/null || true
  fi
fi


echo ""
echo -e "${GREEN}✓ Infrastructure deployed successfully${NC}"
echo ""
echo "Infrastructure pods by namespace:"
echo -e "${YELLOW}→${NC} Redis:"
kubectl get pods -n redis
echo ""
echo -e "${YELLOW}→${NC} Kafka:"
kubectl get pods -n kafka 2>/dev/null || echo "  (Kafka not deployed)"
echo ""
echo -e "${YELLOW}→${NC} RustFS:"
kubectl get pods -n rustfs 2>/dev/null || echo "  (RustFS not deployed)"
echo ""
