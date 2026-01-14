#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
CLUSTER_NAME="dev"
REGISTRY_NAME="kind-registry-dev"
REGISTRY_PORT="5001"
KUBECONFIG_PATH="${PROJECT_ROOT}/.kubeconfig-dev"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "Setting up Kind cluster for local development..."
echo ""

# Check if Kind is installed
if ! command -v kind &>/dev/null; then
	echo -e "${RED}✗ Error: Kind is not installed${NC}"
	echo "Install from: https://kind.sigs.k8s.io/docs/user/quick-start/"
	exit 1
fi

# Check if Docker is running
if ! docker info &>/dev/null; then
	echo -e "${RED}✗ Error: Docker is not running${NC}"
	exit 1
fi

# Stop and remove existing registry if it exists
if docker ps -a --format  '{{.Names}}'  | grep -q "^${REGISTRY_NAME}$"; then
	echo -e "${YELLOW}→${NC} Removing existing registry..."
	docker stop "${REGISTRY_NAME}" 2>/dev/null || true
	docker rm "${REGISTRY_NAME}" 2>/dev/null || true
fi

# Create local registry
echo -e "${YELLOW}→${NC} Creating local Docker registry on port ${REGISTRY_PORT}..."
docker run -d \
	--restart=always \
	-p "127.0.0.1:${REGISTRY_PORT}:5000" \
	--name "${REGISTRY_NAME}" \
	registry:2

# Wait for registry to be ready
sleep 2

# Delete existing cluster if it exists
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
	echo -e "${YELLOW}→${NC} Deleting existing cluster..."
	kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null || true
fi

# Use Kind config file instead of inline config
KIND_CONFIG="${PROJECT_ROOT}/deploy/dev/kind-config.yaml"

if [[ ! -f "$KIND_CONFIG" ]]; then
	echo -e "${RED}✗ Error: Kind config not found at ${KIND_CONFIG}${NC}"
	exit 1
fi

# Create Kind cluster
echo -e "${YELLOW}→${NC} Creating Kind cluster (${CLUSTER_NAME})..."
kind create cluster \
	--name "${CLUSTER_NAME}" \
	--config "${KIND_CONFIG}" \
	--kubeconfig "${KUBECONFIG_PATH}" \
	--wait 5m || {
	echo -e "${RED}✗ Error: Failed to create Kind cluster${NC}"
	exit 1
}

# Connect registry to Kind network
echo -e "${YELLOW}→${NC} Connecting registry to Kind network..."
docker network connect "kind" "${REGISTRY_NAME}" 2>/dev/null || true

# Configure Kind to use local registry
echo -e "${YELLOW}→${NC} Configuring local registry discovery..."
export KUBECONFIG="${KUBECONFIG_PATH}"

kubectl apply -f - <<EOFCONFIG
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOFCONFIG

# Verify cluster is ready
echo -e "${YELLOW}→${NC} Verifying cluster is ready..."
kubectl cluster-info || {
	echo -e "${RED}✗ Error: Cluster is not ready${NC}"
	exit 1
}

kubectl wait --for=condition=Ready nodes --all --timeout=3m || {
	echo -e "${RED}✗ Error: Nodes did not become ready${NC}"
	exit 1
}

echo ""
echo -e "${GREEN}✓ Kind cluster created successfully${NC}"
echo -e "${GREEN}✓ Local registry running at localhost:${REGISTRY_PORT}${NC}"
echo -e "${GREEN}✓ KUBECONFIG=${KUBECONFIG_PATH}${NC}"
echo ""
