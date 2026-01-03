#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
KUBECONFIG_PATH="${PROJECT_ROOT}/.kubeconfig-dev"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

if [[ ! -f "$KUBECONFIG_PATH" ]]; then
  echo -e "${RED}✗ Error: Kubeconfig not found at ${KUBECONFIG_PATH}${NC}"
  echo "Run 'make dev-cluster' first"
  exit 1
fi

export KUBECONFIG="$KUBECONFIG_PATH"

echo -e "${BLUE}=== PostgreSQL Cluster Status ===${NC}"
echo ""

# Check if cluster exists
if ! kubectl get cluster postgres-app -n default &>/dev/null; then
  echo -e "${RED}✗ PostgreSQL cluster 'postgres-app' not found${NC}"
  echo "Run './scripts/dev/deploy-postgres.sh' to deploy"
  exit 1
fi

# Get cluster status
echo -e "${YELLOW}Cluster Overview:${NC}"
kubectl get cluster postgres-app -n default
echo ""

# Get detailed cluster info
echo -e "${YELLOW}Cluster Details:${NC}"
PHASE=$(kubectl get cluster postgres-app -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
INSTANCES=$(kubectl get cluster postgres-app -n default -o jsonpath='{.status.instances}' 2>/dev/null || echo "0")
READY=$(kubectl get cluster postgres-app -n default -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")
PRIMARY=$(kubectl get cluster postgres-app -n default -o jsonpath='{.status.currentPrimary}' 2>/dev/null || echo "None")
PG_VERSION=$(kubectl get cluster postgres-app -n default -o jsonpath='{.status.currentPrimaryTimestamp}' 2>/dev/null || echo "Unknown")

echo "  Phase: $PHASE"
echo "  Primary: $PRIMARY"
echo "  Instances: $READY/$INSTANCES ready"
echo ""

# Get pod status
echo -e "${YELLOW}Pod Status:${NC}"
kubectl get pods -l cnpg.io/cluster=postgres-app -n default -o wide
echo ""

# Get service endpoints
echo -e "${YELLOW}Service Endpoints:${NC}"
kubectl get svc -l cnpg.io/cluster=postgres-app -n default
echo ""

# Get PVC status
echo -e "${YELLOW}Storage (PVC):${NC}"
kubectl get pvc -l cnpg.io/cluster=postgres-app -n default
echo ""

# Check for backups
echo -e "${YELLOW}Backups:${NC}"
if kubectl get backup -n default &>/dev/null; then
  kubectl get backup -l cnpg.io/cluster=postgres-app -n default 2>/dev/null || echo "  No backups found"
else
  echo "  Backup CRD not available"
fi
echo ""

# Check replication lag (if replicas exist)
if [[ "$INSTANCES" -gt 1 ]] && [[ "$READY" -gt 1 ]]; then
  echo -e "${YELLOW}Replication Status:${NC}"
  
  # Get primary pod name
  PRIMARY_POD=$(kubectl get pods -l cnpg.io/cluster=postgres-app,role=primary -n default -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  
  if [[ -n "$PRIMARY_POD" ]]; then
    echo "  Checking replication lag from primary: $PRIMARY_POD"
    
    # Query replication status
    kubectl exec -n default "$PRIMARY_POD" -- psql -U postgres -c "SELECT client_addr, state, sync_state, replay_lag FROM pg_stat_replication;" 2>/dev/null || echo "  Unable to query replication status"
  else
    echo "  Primary pod not found"
  fi
  echo ""
fi

# Connection info
echo -e "${YELLOW}Connection Information:${NC}"
echo "  Primary (RW): postgres-app-rw.default.svc.cluster.local:5432"
echo "  Replicas (RO): postgres-app-ro.default.svc.cluster.local:5432"
echo ""
echo "  Get superuser password:"
echo "    kubectl get secret postgres-app-superuser -n default -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "  Port forward to localhost:"
echo "    ./scripts/dev/port-forward-postgres.sh"
echo ""

# Health check
if [[ "$PHASE" == "Cluster in healthy state" ]] && [[ "$READY" == "$INSTANCES" ]]; then
  echo -e "${GREEN}✓ Cluster is healthy${NC}"
  exit 0
else
  echo -e "${YELLOW}⚠ Cluster is not fully healthy${NC}"
  exit 1
fi
