#!/bin/bash
set -euo pipefail

# Get scenario from environment (set by workflow)
SCENARIO="${SCENARIO:-}"
if [[ -z "$SCENARIO" ]]; then
  echo "Error: SCENARIO environment variable not set"
  exit 1
fi

INCLUDE_S3="${1:-false}"
NAMESPACE="e2e-test-${SCENARIO}"

echo "Deploying infrastructure in namespace: ${NAMESPACE}..."

echo "Deploying Redis..."
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: ${NAMESPACE}
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
  namespace: ${NAMESPACE}
spec:
  selector:
    app: redis
  ports:
  - port: 6379
    targetPort: 6379
EOF

echo "Waiting for Redis..."
kubectl wait --for=condition=Ready pod -l app=redis -n ${NAMESPACE} --timeout=3m

if [ "$INCLUDE_S3" = "true" ]; then
  echo "Deploying MinIO..."
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
      - name: minio
        image: minio/minio:latest
        args: ["server", "/data", "--console-address", ":9001"]
        env:
        - name: MINIO_ROOT_USER
          value: "minioadmin"
        - name: MINIO_ROOT_PASSWORD
          value: "minioadmin"
        ports:
        - containerPort: 9000
          name: api
        - containerPort: 9001
          name: console
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: ${NAMESPACE}
spec:
  selector:
    app: minio
  ports:
  - name: api
    port: 9000
    targetPort: 9000
  - name: console
    port: 9001
    targetPort: 9001
EOF

  echo "Waiting for MinIO..."
  kubectl wait --for=condition=Ready pod -l app=minio -n ${NAMESPACE} --timeout=3m
  
  echo "Creating MinIO bucket..."
  kubectl run minio-init --rm -i --restart=Never -n ${NAMESPACE} --image=minio/mc:latest -- \
    sh -c "mc alias set local http://minio.${NAMESPACE}.svc.cluster.local:9000 minioadmin minioadmin && mc mb local/data --ignore-existing" || true

  echo "✓ MinIO deployed and initialized"
else
  echo "Skipping MinIO (S3 not enabled)"
fi

echo "✓ Infrastructure deployed"
