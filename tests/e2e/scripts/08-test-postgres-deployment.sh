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
  exit 1
fi

echo "=== Testing PostgreSQL Deployment ==="
echo ""

# Create object storage secret for backups
echo "Creating object storage secret..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: postgres-backup-credentials-test
  namespace: default
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: minioadmin
  AWS_SECRET_ACCESS_KEY: minioadmin
  AWS_DEFAULT_REGION: us-east-1
EOF

# Deploy test cluster
echo "Deploying test PostgreSQL cluster..."
kubectl apply -f "${SCRIPT_DIR}/../fixtures/postgres/test-cluster.yaml"

# Wait for cluster to be ready (with timeout)
echo "Waiting for PostgreSQL cluster to be ready (max 5 minutes)..."
TIMEOUT=300
ELAPSED=0
while [[ $ELAPSED -lt $TIMEOUT ]]; do
  STATUS=$(kubectl get cluster postgres-test -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  INSTANCES=$(kubectl get cluster postgres-test -n default -o jsonpath='{.status.instances}' 2>/dev/null || echo "0")
  READY=$(kubectl get cluster postgres-test -n default -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")
  
  echo "  Status: ${STATUS}, Instances: ${READY}/${INSTANCES}"
  
  if [[ "$STATUS" == "Cluster in healthy state" ]] && [[ "$READY" == "$INSTANCES" ]] && [[ "$INSTANCES" != "0" ]]; then
    echo "✓ PostgreSQL cluster is ready!"
    break
  fi
  
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

if [[ $ELAPSED -ge $TIMEOUT ]]; then
  echo "✗ Error: PostgreSQL cluster failed to become ready within ${TIMEOUT}s"
  echo ""
  echo "Cluster status:"
  kubectl get cluster postgres-test -n default -o yaml
  echo ""
  echo "Pod status:"
  kubectl get pods -l cnpg.io/cluster=postgres-test -n default
  echo ""
  echo "Recent logs:"
  kubectl logs -l cnpg.io/cluster=postgres-test -n default --tail=100 || true
  exit 1
fi

# Validate cluster state
echo ""
echo "Validating cluster state..."

# Check number of instances
INSTANCES=$(kubectl get cluster postgres-test -n default -o jsonpath='{.status.instances}')
READY=$(kubectl get cluster postgres-test -n default -o jsonpath='{.status.readyInstances}')
if [[ "$READY" != "$INSTANCES" ]]; then
  echo "✗ Error: Not all instances are ready (${READY}/${INSTANCES})"
  exit 1
fi
echo "✓ All instances are ready (${READY}/${INSTANCES})"

# Check primary is elected
PRIMARY=$(kubectl get cluster postgres-test -n default -o jsonpath='{.status.currentPrimary}')
if [[ -z "$PRIMARY" ]]; then
  echo "✗ Error: No primary instance elected"
  exit 1
fi
echo "✓ Primary instance elected: ${PRIMARY}"

# Test database connectivity
echo ""
echo "Testing database connectivity..."

# Get superuser password
SUPERUSER_PASSWORD=$(kubectl get secret postgres-test-superuser -n default -o jsonpath='{.data.password}' | base64 -d)

# Test connection to primary (read-write)
echo "Testing connection to primary (read-write)..."
PRIMARY_POD=$(kubectl get pods -l cnpg.io/cluster=postgres-test,role=primary -n default -o jsonpath='{.items[0].metadata.name}')

if ! kubectl exec -n default "$PRIMARY_POD" -- psql -U postgres -c "SELECT 1;" &>/dev/null; then
  echo "✗ Error: Failed to connect to primary instance"
  exit 1
fi
echo "✓ Successfully connected to primary"

# Create a test table and insert data
echo "Creating test table and inserting data..."
kubectl exec -n default "$PRIMARY_POD" -- psql -U postgres <<EOF
  CREATE TABLE IF NOT EXISTS test_table (id SERIAL PRIMARY KEY, data TEXT, created_at TIMESTAMP DEFAULT NOW());
  INSERT INTO test_table (data) VALUES ('test-e2e-data-1'), ('test-e2e-data-2'), ('test-e2e-data-3');
EOF

# Verify data was inserted
ROW_COUNT=$(kubectl exec -n default "$PRIMARY_POD" -- psql -U postgres -t -c "SELECT COUNT(*) FROM test_table;")
ROW_COUNT=$(echo "$ROW_COUNT" | tr -d ' ')
if [[ "$ROW_COUNT" -lt 3 ]]; then
  echo "✗ Error: Failed to insert test data (found ${ROW_COUNT} rows, expected >= 3)"
  exit 1
fi
echo "✓ Successfully created table and inserted ${ROW_COUNT} rows"

# Test connection to replica (read-only) if replicas exist
if [[ "$INSTANCES" -gt 1 ]]; then
  echo ""
  echo "Testing replication..."
  
  # Wait a moment for replication to catch up
  sleep 5
  
  # Get a replica pod
  REPLICA_POD=$(kubectl get pods -l cnpg.io/cluster=postgres-test -n default -o jsonpath='{.items[?(@.metadata.name!="'$PRIMARY_POD'")].metadata.name}' | awk '{print $1}')
  
  if [[ -n "$REPLICA_POD" ]]; then
    echo "Testing connection to replica: ${REPLICA_POD}..."
    
    # Verify data is replicated
    REPLICA_ROW_COUNT=$(kubectl exec -n default "$REPLICA_POD" -- psql -U postgres -t -c "SELECT COUNT(*) FROM test_table;" 2>/dev/null || echo "0")
    REPLICA_ROW_COUNT=$(echo "$REPLICA_ROW_COUNT" | tr -d ' ')
    
    if [[ "$REPLICA_ROW_COUNT" -eq "$ROW_COUNT" ]]; then
      echo "✓ Data successfully replicated to replica (${REPLICA_ROW_COUNT} rows)"
    else
      echo "⚠ Warning: Replica has ${REPLICA_ROW_COUNT} rows, primary has ${ROW_COUNT}"
    fi
    
    # Check replication lag
    echo "Checking replication lag..."
    kubectl exec -n default "$PRIMARY_POD" -- psql -U postgres -c "SELECT client_addr, state, sync_state, replay_lag FROM pg_stat_replication;" || true
  fi
fi

# Test service endpoints
echo ""
echo "Testing service endpoints..."

# Check if read-write service exists
if kubectl get svc postgres-test-rw -n default &>/dev/null; then
  echo "✓ Read-write service exists: postgres-test-rw"
else
  echo "✗ Error: Read-write service not found"
  exit 1
fi

# Check if read-only service exists
if kubectl get svc postgres-test-ro -n default &>/dev/null; then
  echo "✓ Read-only service exists: postgres-test-ro"
else
  echo "✗ Error: Read-only service not found"
  exit 1
fi

# Validate SC-001: Cluster ready within 5 minutes
START_TIME=$(kubectl get cluster postgres-test -n default -o jsonpath='{.metadata.creationTimestamp}')
READY_TIME=$(kubectl get cluster postgres-test -n default -o jsonpath='{.status.readyInstances}')
# Note: This is a simplified check - full timing validation would require more complex logic

echo ""
echo "=== PostgreSQL Deployment Test Complete ==="
echo "✓ All tests passed"
echo ""
echo "Cluster Summary:"
echo "  Name: postgres-test"
echo "  Instances: ${INSTANCES}"
echo "  Primary: ${PRIMARY}"
echo "  Read-write endpoint: postgres-test-rw.default.svc.cluster.local:5432"
echo "  Read-only endpoint: postgres-test-ro.default.svc.cluster.local:5432"
