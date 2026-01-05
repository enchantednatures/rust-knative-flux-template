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

echo "Deploying infrastructure services..."
echo ""

# Create infrastructure namespaces
echo -e "${YELLOW}→${NC} Creating infrastructure namespaces..."
kubectl create namespace redis 2>/dev/null || true
kubectl create namespace kafka 2>/dev/null || true
kubectl create namespace minio 2>/dev/null || true

# Deploy infrastructure
echo -e "${YELLOW}→${NC} Deploying Redis, Kafka, and MinIO..."
kubectl apply -k deploy/dev/infrastructure || {
  echo -e "${RED}✗ Error: Failed to deploy infrastructure${NC}"
  exit 1
}

echo -e "${YELLOW}→${NC} Waiting for Redis to be ready..."
if ! kubectl wait --for=condition=Ready pod -l app=redis -n redis --timeout=3m; then
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

# Check for MinIO in the manifest
if kubectl get statefulset minio -n minio 2>/dev/null || kubectl get deployment minio -n minio 2>/dev/null; then
  echo -e "${YELLOW}→${NC} Waiting for MinIO to be ready..."
  if ! kubectl wait --for=condition=Ready pod -l app=minio -n minio --timeout=5m; then
    echo -e "${RED}✗ Error: MinIO failed to become ready${NC}"
    echo ""
    echo "=== Pod Status ==="
    kubectl get pods -n minio -l app=minio
    echo ""
    echo "=== Pod Logs ==="
    kubectl logs -l app=minio -n minio --tail=100 --all-containers=true 2>&1 || true
    echo ""
    echo "=== Pod Descriptions ==="
    kubectl describe pods -l app=minio -n minio | head -100
    echo ""
    echo "=== Events ==="
    kubectl get events -n minio --sort-by='.lastTimestamp' | tail -20
    exit 1
  fi
  
  echo -e "${YELLOW}→${NC} Waiting for MinIO bucket initialization..."
  if ! kubectl wait --for=condition=complete job/minio-init -n minio --timeout=2m 2>/dev/null; then
    echo -e "${YELLOW}⚠${NC} MinIO bucket creation may be pending, checking job..."
    kubectl logs -n minio job/minio-init 2>/dev/null || true
  fi
fi

# Check for Kafka in the manifest
if kubectl get statefulset kafka -n kafka 2>/dev/null; then
  echo -e "${YELLOW}→${NC} Waiting for Kafka to be ready..."
  if ! kubectl wait --for=condition=Ready pod -l app=kafka -n kafka --timeout=5m; then
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
echo -e "${YELLOW}→${NC} MinIO:"
kubectl get pods -n minio 2>/dev/null || echo "  (MinIO not deployed)"
echo ""
