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

echo "Deploying infrastructure services..."
echo ""

# Create services namespace
echo -e "${YELLOW}→${NC} Creating services namespace..."
kubectl create namespace services 2>/dev/null || true

# Deploy infrastructure
echo -e "${YELLOW}→${NC} Deploying Redis and infrastructure..."
kubectl apply -k deploy/dev/infrastructure || {
  echo -e "${RED}✗ Error: Failed to deploy infrastructure${NC}"
  exit 1
}

echo -e "${YELLOW}→${NC} Waiting for Redis to be ready..."
if ! kubectl wait --for=condition=Ready pod -l app=redis -n services --timeout=3m; then
  echo -e "${RED}✗ Error: Redis failed to become ready${NC}"
  echo ""
  echo "Pod status:"
  kubectl get pods -n services -l app=redis
  echo ""
  echo "Recent logs:"
  kubectl logs -l app=redis -n services --tail=50
  exit 1
fi

# Check for MinIO in the manifest
if kubectl get statefulset minio -n services 2>/dev/null || kubectl get deployment minio -n services 2>/dev/null; then
  echo -e "${YELLOW}→${NC} Waiting for MinIO to be ready..."
  if ! kubectl wait --for=condition=Ready pod -l app=minio -n services --timeout=5m; then
    echo -e "${RED}✗ Error: MinIO failed to become ready${NC}"
    echo ""
    echo "Pod status:"
    kubectl get pods -n services -l app=minio
    echo ""
    echo "Recent logs:"
    kubectl logs -l app=minio -n services --tail=50
    exit 1
  fi
  
  echo -e "${YELLOW}→${NC} Waiting for MinIO bucket initialization..."
  if ! kubectl wait --for=condition=complete job/minio-init -n services --timeout=2m 2>/dev/null; then
    echo -e "${YELLOW}⚠${NC} MinIO bucket creation may be pending, checking job..."
    kubectl logs -n services job/minio-init 2>/dev/null || true
  fi
fi

# Check for Kafka in the manifest
if kubectl get statefulset kafka -n services 2>/dev/null; then
  echo -e "${YELLOW}→${NC} Waiting for Kafka to be ready..."
  if ! kubectl wait --for=condition=Ready pod -l app=kafka -n services --timeout=5m; then
    echo -e "${RED}✗ Error: Kafka failed to become ready${NC}"
    echo ""
    echo "Pod status:"
    kubectl get pods -n services -l app=kafka
    echo ""
    echo "Recent logs:"
    kubectl logs -l app=kafka -n services --tail=50
    exit 1
  fi
  
  echo -e "${YELLOW}→${NC} Waiting for Kafka topic initialization..."
  if ! kubectl wait --for=condition=complete job/kafka-topic-init -n services --timeout=2m 2>/dev/null; then
    echo -e "${YELLOW}⚠${NC} Kafka topic creation may be pending, checking job..."
    kubectl logs -n services job/kafka-topic-init 2>/dev/null || true
  fi
fi


echo ""
echo -e "${GREEN}✓ Infrastructure deployed successfully${NC}"
kubectl get pods -n services
echo ""
