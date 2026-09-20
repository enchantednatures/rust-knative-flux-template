#!/bin/bash
set -euo pipefail

# Test PostgreSQL Deployment (shipped CloudNativePG stack)
#
# Validates the template-shipped cluster (deploy/components/postgres) rather
# than a standalone fixture: e2e runs take <project>-postgres through the same
# manifests Flux applies in dev/staging/prod.
#
# Usage:
#   ./08-test-postgres-deployment.sh            (SCENARIO env set by workflow)
#   PROJECT_NAME=my-app ./08-test-postgres-deployment.sh
#
# Skips gracefully when the project does not enable feature_postgres (no
# deploy/components/postgres manifests rendered/in cluster).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${SCENARIO:-}" ]]; then
  export KUBECONFIG="${SCRIPT_DIR}/.kubeconfig-${SCENARIO}"
fi

PROJECT_NAME="${PROJECT_NAME:-example-app}"
# Scripts/deploy tooling uses kebab-case Kubernetes names everywhere.
CLUSTER_NAME="${PROJECT_NAME}-postgres"
NAMESPACE="${NAMESPACE:-default}"

if [ -d "deploy/components/postgres" ]; then
  echo "=== Deploying the shipped CloudNativePG component ==="
  kubectl apply --server-side -k deploy/components/postgres
else
  echo "=== Using already-deployed cluster (component dir absent in this scenario) ==="
fi

if ! kubectl get cluster "$CLUSTER_NAME" -n "$NAMESPACE" &>/dev/null; then
  echo "PostgreSQL cluster '${CLUSTER_NAME}' not present - feature_postgres is disabled."
  echo "Skipping PostgreSQL e2e (0 tests failed)."
  exit 0
fi

echo "=== Testing PostgreSQL Deployment (${CLUSTER_NAME}) ==="
echo ""

TIMEOUT=600
ELAPSED=0
while [[ $ELAPSED -lt $TIMEOUT ]]; do
  STATUS=$(kubectl get cluster "$CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  INSTANCES=$(kubectl get cluster "$CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.instances}' 2>/dev/null || echo "0")
  READY=$(kubectl get cluster "$CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")

  echo "  Status: ${STATUS}, Instances: ${READY}/${INSTANCES}"

  if [[ "$STATUS" == "Cluster in healthy state" ]] && [[ "$READY" == "$INSTANCES" ]] && [[ "$INSTANCES" != "0" ]]; then
    echo "✓ PostgreSQL cluster is ready"
    break
  fi

  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

if [[ $ELAPSED -ge $TIMEOUT ]]; then
  echo "✗ Error: PostgreSQL cluster failed to become ready within ${TIMEOUT}s"
  kubectl get cluster "$CLUSTER_NAME" -n "$NAMESPACE" -o yaml
  kubectl get pods -l cnpg.io/cluster="$CLUSTER_NAME" -n "$NAMESPACE"
  kubectl logs -l cnpg.io/cluster="$CLUSTER_NAME" -n "$NAMESPACE" --tail=100 || true
  exit 1
fi

PRIMARY_POD=$(kubectl get pods -n "$NAMESPACE" \
  -l cnpg.io/cluster="$CLUSTER_NAME",cnpg.io/instanceRole=primary \
  -o jsonpath='{.items[0].metadata.name}')

_secret() { kubectl get secret "$1" -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d; }
APP_PASSWORD=$(_secret "${CLUSTER_NAME}-app") || true

echo ""
echo "Testing database connectivity (user app, db app)..."
if ! kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -- psql -U app -d app -c "SELECT 1;" &>/dev/null; then
  echo "✗ Error: could not connect to the primary as app user"
  exit 1
fi
echo "✓ Connected to primary"

echo ""
echo "Validating app secret and service endpoints..."
kubectl get secret "${CLUSTER_NAME}-app" -n "$NAMESPACE" >/dev/null \
  && echo "✓ App secret '${CLUSTER_NAME}-app' exists (keys: username/password/host/dbname/uri)" \
  || { echo "✗ Error: app secret missing"; exit 1; }
kubectl get svc "${CLUSTER_NAME}-rw" -n "$NAMESPACE" >/dev/null \
  && echo "✓ Read-write service '${CLUSTER_NAME}-rw' exists" \
  || { echo "✗ Error: rw service missing"; exit 1; }
kubectl get svc "${CLUSTER_NAME}-r" -n "$NAMESPACE" >/dev/null \
  && echo "✓ Any-node service '${CLUSTER_NAME}-r' exists" \
  || { echo "✗ Error: r service missing"; exit 1; }

echo ""
echo "Validating demo_items table (embedded sqlx migration)..."
TABLE_COUNT=$(kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -- psql -U app -d app -t -A -c \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_name='demo_items';")
if [[ "$TABLE_COUNT" != "1" ]]; then
  echo "✗ Error: demo_items table missing (the app's initial migration did not run)"
  kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -- psql -U app -d app -c '\dt'
  exit 1
fi
echo "✓ demo_items table created by migration 0001"

echo ""
echo "Exercising upsert semantics (INSERT ... ON CONFLICT (key) DO UPDATE)..."
kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -- psql -U app -d app -c \
  "INSERT INTO demo_items (key, value) VALUES ('e2e-key', 'v1')
   ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();"
kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -- psql -U app -d app -c \
  "INSERT INTO demo_items (key, value) VALUES ('e2e-key', 'v2')
   ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();"
VALUE=$(kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -- psql -U app -d app -t -A -c \
  "SELECT value FROM demo_items WHERE key='e2e-key';")
if [[ "$VALUE" == "v2" ]]; then
  echo "✓ Upsert returned a single row with the latest value (v2)"
else
  echo "✗ Error: upsert produced unexpected value: '$VALUE'"
  exit 1
fi

echo ""
echo "=== PostgreSQL Deployment Test Complete ==="
echo "Cluster Summary:"
echo "  Name: ${CLUSTER_NAME}"
echo "  Instances: $(kubectl get cluster "$CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.instances}')"
echo "  Primary pod: ${PRIMARY_POD}"
echo "  RW endpoint: ${CLUSTER_NAME}-rw.${NAMESPACE}.svc.cluster.local:5432"
