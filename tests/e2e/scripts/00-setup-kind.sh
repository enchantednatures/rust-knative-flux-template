#!/bin/bash
set -euo pipefail

SCENARIO="${1:-with-s3}"
CLUSTER_NAME="e2e-${SCENARIO}"

# Use different ports for each scenario to allow parallel execution
if [[ "$SCENARIO" == "no-s3" ]]; then
  HOST_PORT=8080
elif [[ "$SCENARIO" == "with-s3" ]]; then
  HOST_PORT=8081
else
  HOST_PORT=8080
fi

echo "Creating Kind cluster: ${CLUSTER_NAME} (using host port ${HOST_PORT})..."

# Create temporary Kind config with scenario-specific port
TEMP_CONFIG=$(mktemp)
cat > "${TEMP_CONFIG}" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      # Map Kourier to host for external access
      - containerPort: 31080
        hostPort: ${HOST_PORT}
        protocol: TCP
EOF

kind create cluster \
  --name "${CLUSTER_NAME}" \
  --config "${TEMP_CONFIG}" \
  --wait 5m

rm -f "${TEMP_CONFIG}"

echo "Verifying cluster..."
kubectl cluster-info --context "kind-${CLUSTER_NAME}"
kubectl wait --for=condition=Ready nodes --all --timeout=3m

echo "✓ Kind cluster ready (accessible on localhost:${HOST_PORT})"
