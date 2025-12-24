#!/bin/bash
set -euo pipefail

SCENARIO="${1:-with-s3}"
CLUSTER_NAME="e2e-${SCENARIO}"
REGISTRY_NAME="kind-registry-${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Use different ports for each scenario to allow parallel execution
if [[ "$SCENARIO" == "no-s3" ]]; then
  HOST_PORT=8080
  REGISTRY_PORT=5000
elif [[ "$SCENARIO" == "with-s3" ]]; then
  HOST_PORT=8081
  REGISTRY_PORT=5001
else
  HOST_PORT=8080
  REGISTRY_PORT=5000
fi

echo "Setting up local Docker registry: ${REGISTRY_NAME} on port ${REGISTRY_PORT}..."

# Stop and remove existing registry if it exists
if docker ps -a --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
  echo "Removing existing registry: ${REGISTRY_NAME}"
  docker stop "${REGISTRY_NAME}" || true
  docker rm "${REGISTRY_NAME}" || true
fi

# Create local registry
docker run -d --restart=always -p "127.0.0.1:${REGISTRY_PORT}:5000" --name "${REGISTRY_NAME}" registry:2

echo "Creating Kind cluster: ${CLUSTER_NAME} (using host port ${HOST_PORT})..."

# Delete existing cluster if it exists
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  echo "Deleting existing cluster: ${CLUSTER_NAME}"
  kind delete cluster --name "${CLUSTER_NAME}" || true
fi

# Create dedicated kubeconfig for this scenario
export KUBECONFIG="${SCRIPT_DIR}/.kubeconfig-${SCENARIO}"
rm -f "$KUBECONFIG"

# Create temporary Kind config with scenario-specific port
TEMP_CONFIG=$(mktemp)
cat > "${TEMP_CONFIG}" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
featureGates:
  KubeletInUserNamespace: true
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
            feature-gates: "KubeletInUserNamespace=true"
      - |
        kind: KubeletConfiguration
        featureGates:
          KubeletInUserNamespace: true
    extraPortMappings:
      # Map Kourier to host for external access
      - containerPort: 31080
        hostPort: ${HOST_PORT}
        protocol: TCP
EOF

kind create cluster \
  --name "${CLUSTER_NAME}" \
  --config "${TEMP_CONFIG}" \
  --kubeconfig "$KUBECONFIG" \
  --wait 5m

rm -f "${TEMP_CONFIG}"

echo "Connecting registry to Kind network..."
docker network connect "kind" "${REGISTRY_NAME}" 2>/dev/null || true

echo "Configuring Kind to use local registry..."
# Document the local registry in the cluster
# https://github.com/kubernetes/enhancements/tree/master/keps/sig-cluster-lifecycle/generic/1755-communicating-a-local-registry
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

echo "Verifying cluster..."
kubectl cluster-info
kubectl wait --for=condition=Ready nodes --all --timeout=3m

echo "✓ Local registry running at localhost:${REGISTRY_PORT}"
echo "✓ Kind cluster ready (accessible on localhost:${HOST_PORT})"
echo "✓ KUBECONFIG exported: ${KUBECONFIG}"
