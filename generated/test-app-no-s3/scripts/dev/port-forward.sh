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

echo "Setting up port forwarding to local services..."
echo ""

# Kill existing port-forwards
pkill -f "kubectl.*port-forward" 2>/dev/null || true
sleep 1

# Start port-forwards in background
echo -e "${YELLOW}→${NC} Redis (6379)"
kubectl port-forward -n redis svc/redis 6379:6379 >/dev/null 2>&1 &
REDIS_PID=$!

# MinIO if it exists
MINIO_PID=""
if kubectl get service minio -n minio 2>/dev/null >/dev/null; then
  echo -e "${YELLOW}→${NC} MinIO API (9000)"
  kubectl port-forward -n minio svc/minio 9000:9000 >/dev/null 2>&1 &
  MINIO_API_PID=$!
  
  echo -e "${YELLOW}→${NC} MinIO Console (9001)"
  kubectl port-forward -n minio svc/minio 9001:9001 >/dev/null 2>&1 &
  MINIO_CONSOLE_PID=$!
fi

# Observability
echo -e "${YELLOW}→${NC} Jaeger UI (16686)"
kubectl port-forward -n observability svc/jaeger 16686:16686 >/dev/null 2>&1 &
JAEGER_PID=$!

echo -e "${YELLOW}→${NC} Prometheus (9090)"
kubectl port-forward -n observability svc/prometheus 9090:9090 >/dev/null 2>&1 &
PROMETHEUS_PID=$!

echo ""
echo -e "${GREEN}✓ Port forwarding active${NC}"
echo ""
echo "Access your services:"
echo "  • Application:   http://localhost:8080"
echo "  • Jaeger UI:     http://localhost:16686"
echo "  • Prometheus:    http://localhost:9090"
echo "  • Redis:         localhost:6379"
if kubectl get service minio -n minio 2>/dev/null >/dev/null; then
  echo "  • MinIO API:     http://localhost:9000"
  echo "  • MinIO Console: http://localhost:9001 (admin/minioadmin)"
fi
echo ""
echo "Press Ctrl+C to stop port forwarding..."
echo ""

# Keep script running
wait
