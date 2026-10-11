#!/bin/bash
set -euo pipefail

# Get scenario from environment (set by workflow)
SCENARIO="${SCENARIO:-}"
if [[ -z "$SCENARIO" ]]; then
  echo "Error: SCENARIO environment variable not set"
  exit 1
fi

# Use scenario-specific kubeconfig
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${SCRIPT_DIR}/.kubeconfig-${SCENARIO}"

if [[ ! -f "$KUBECONFIG" ]]; then
  echo "Error: Kubeconfig not found: $KUBECONFIG"
  echo "Did you run 00-setup-kind.sh first?"
  exit 1
fi

if feature_s3="${1:-false}"

echo "Creating services namespace..."
kubectl create namespace services 2>/dev/null || true

echo "Deploying Redis..."
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: services
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
        args: ["redis-server", "--appendonly", "yes"]
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: services
spec:
  selector:
    app: redis
  ports:
  - port: 6379
    targetPort: 6379
EOF

echo "Waiting for Redis..."
kubectl wait --for=condition=Ready pod -l app=redis -n services --timeout=3m

echo "Verifying Redis is accepting connections..."
# Give Redis a moment to fully start accepting connections
sleep 5
# Test Redis connectivity
if ! kubectl run redis-verify --rm -i --restart=Never --image=redis:7-alpine -n services --command -- \
  redis-cli -h redis.services.svc.cluster.local ping 2>&1 | grep -q PONG; then
  echo "❌ Warning: Redis is not responding to PING"
  kubectl get pods -n services -l app=redis
  # Don't exit, let the deployment script handle this
fi

if [ "$if feature_s3" = "true" ]; then
  echo "Deploying RustFS..."
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rustfs
  namespace: services
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rustfs
  template:
    metadata:
      labels:
        app: rustfs
    spec:
      containers:
      - name: rustfs
        image: rustfs/rustfs:1.0.1
        args: ["/data"]
        env:
        - name: RUSTFS_ACCESS_KEY
          value: "rustfsadmin"
        - name: RUSTFS_SECRET_KEY
          value: "rustfsadmin"
        ports:
        - containerPort: 9000
          name: api
        - containerPort: 9001
          name: console
---
apiVersion: v1
kind: Service
metadata:
  name: rustfs
  namespace: services
spec:
  selector:
    app: rustfs
  ports:
  - name: api
    port: 9000
    targetPort: 9000
  - name: console
    port: 9001
    targetPort: 9001
EOF

  echo "Waiting for RustFS..."
  kubectl wait --for=condition=Ready pod -l app=rustfs -n services --timeout=3m
  
  echo "Creating RustFS bucket..."
  # Give RustFS a moment to fully start
  sleep 5
  
  # Create bucket using a Job instead of run --rm to avoid TTY issues
  cat <<'EOFRUSTFS' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: rustfs-init
  namespace: services
spec:
  ttlSecondsAfterFinished: 60
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: rc
        image: rustfs/rc:v0.1.36
        command:
        - /bin/sh
        - -c
        - |
          until rc alias set local http://rustfs.services.svc.cluster.local:9000 rustfsadmin rustfsadmin; do sleep 2; done
          rc bucket create -p local/data
          echo "Bucket creation completed"
EOFRUSTFS

  echo "Waiting for RustFS bucket creation..."
  kubectl wait --for=condition=complete job/rustfs-init -n services --timeout=2m || echo "Warning: Bucket creation may have failed"
  kubectl logs -n services job/rustfs-init || true

  echo "✓ RustFS deployed and initialized"
else
  echo "Skipping RustFS (S3 not enabled)"
fi

echo "✓ Infrastructure deployed"
