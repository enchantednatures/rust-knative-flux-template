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
  echo "Run 'make dev-cluster' or './scripts/dev/setup-kind.sh' first"
  exit 1
fi

export KUBECONFIG="$KUBECONFIG_PATH"

echo "Deploying PostgreSQL with CloudNativePG..."
echo ""

# Install CloudNativePG operator
echo -e "${YELLOW}→${NC} Installing CloudNativePG operator..."
kubectl apply -k deploy/infrastructure/cloudnative-pg/operator || {
  echo -e "${RED}✗ Error: Failed to install CloudNativePG operator${NC}"
  exit 1
}

echo -e "${YELLOW}→${NC} Waiting for CloudNativePG operator to be ready..."
if ! kubectl wait --for=condition=Available deployment/cnpg-controller-manager \
  -n cnpg-system --timeout=3m 2>/dev/null; then
  echo -e "${RED}✗ Error: CloudNativePG operator failed to become ready${NC}"
  echo ""
  echo "Deployment status:"
  kubectl get deployment -n cnpg-system
  echo ""
  echo "Recent logs:"
  kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg --tail=50 2>/dev/null || true
  exit 1
fi

# Install Barman Cloud Plugin
echo -e "${YELLOW}→${NC} Installing Barman Cloud Plugin..."
kubectl apply -k deploy/infrastructure/cloudnative-pg/plugin || {
  echo -e "${RED}✗ Error: Failed to install Barman Cloud Plugin${NC}"
  exit 1
}

echo -e "${YELLOW}→${NC} Waiting for Barman Cloud Plugin to be ready..."
if ! kubectl wait --for=condition=Available deployment/barman-cloud-operator \
  -n cnpg-system --timeout=3m 2>/dev/null; then
  echo -e "${RED}✗ Error: Barman Cloud Plugin failed to become ready${NC}"
  echo ""
  echo "Deployment status:"
  kubectl get deployment -n cnpg-system
  exit 1
fi

# Deploy MinIO for object storage (development)
echo -e "${YELLOW}→${NC} Deploying MinIO for backup storage..."
kubectl apply -f deploy/overlays/dev/infrastructure/minio.yaml || {
  echo -e "${RED}✗ Error: Failed to deploy MinIO${NC}"
  exit 1
}

echo -e "${YELLOW}→${NC} Waiting for MinIO to be ready..."
if ! kubectl wait --for=condition=Ready pod -l app=minio -n minio --timeout=3m; then
  echo -e "${RED}✗ Error: MinIO failed to become ready${NC}"
  echo ""
  echo "Pod status:"
  kubectl get pods -n minio -l app=minio
  echo ""
  echo "Recent logs:"
  kubectl logs -l app=minio -n minio --tail=50
  exit 1
fi

# Create object storage secret
echo -e "${YELLOW}→${NC} Creating object storage secret..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: postgres-backup-credentials
  namespace: default
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: minioadmin
  AWS_SECRET_ACCESS_KEY: minioadmin
  AWS_DEFAULT_REGION: us-east-1
EOF

# Deploy PostgreSQL cluster
echo -e "${YELLOW}→${NC} Deploying PostgreSQL cluster..."
kubectl apply -k deploy/overlays/dev || {
  echo -e "${RED}✗ Error: Failed to deploy PostgreSQL cluster${NC}"
  exit 1
}

echo -e "${YELLOW}→${NC} Waiting for PostgreSQL cluster to be ready (this may take 2-3 minutes)..."
# Wait for the cluster to be created
sleep 10

# Check if cluster exists
if ! kubectl get cluster postgres-app -n default &>/dev/null; then
  echo -e "${RED}✗ Error: PostgreSQL cluster was not created${NC}"
  exit 1
fi

# Wait for cluster to be ready
TIMEOUT=300
ELAPSED=0
while [[ $ELAPSED -lt $TIMEOUT ]]; do
  STATUS=$(kubectl get cluster postgres-app -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  INSTANCES=$(kubectl get cluster postgres-app -n default -o jsonpath='{.status.instances}' 2>/dev/null || echo "0")
  READY=$(kubectl get cluster postgres-app -n default -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")
  
  echo -e "${YELLOW}→${NC} Cluster status: ${STATUS}, Instances: ${READY}/${INSTANCES}"
  
  if [[ "$STATUS" == "Cluster in healthy state" ]] && [[ "$READY" == "$INSTANCES" ]] && [[ "$INSTANCES" != "0" ]]; then
    echo -e "${GREEN}✓${NC} PostgreSQL cluster is ready!"
    break
  fi
  
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

if [[ $ELAPSED -ge $TIMEOUT ]]; then
  echo -e "${RED}✗ Error: PostgreSQL cluster failed to become ready within ${TIMEOUT}s${NC}"
  echo ""
  echo "Cluster status:"
  kubectl get cluster postgres-app -n default -o yaml
  echo ""
  echo "Pod status:"
  kubectl get pods -l cnpg.io/cluster=postgres-app -n default
  echo ""
  echo "Recent logs:"
  kubectl logs -l cnpg.io/cluster=postgres-app -n default --tail=50 || true
  exit 1
fi

echo ""
echo -e "${GREEN}✓ PostgreSQL deployment complete!${NC}"
echo ""
echo "Connection details:"
echo "  Primary (read-write): postgres-app-rw.default.svc.cluster.local:5432"
echo "  Replicas (read-only): postgres-app-ro.default.svc.cluster.local:5432"
echo "  Service account:      postgres-app"
echo ""
echo "To get the superuser password:"
echo "  kubectl get secret postgres-app-superuser -n default -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "To get the app user password:"
echo "  kubectl get secret postgres-app-app -n default -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "To forward PostgreSQL port to localhost:"
echo "  ./scripts/dev/port-forward-postgres.sh"
