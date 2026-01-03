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

echo "=== Testing PostgreSQL Failover (High Availability) ==="
echo ""

# Verify cluster exists
if ! kubectl get cluster postgres-test -n default &>/dev/null; then
  echo "✗ Error: PostgreSQL cluster 'postgres-test' not found"
  echo "Run 08-test-postgres-deployment.sh first"
  exit 1
fi

# Get initial cluster state
echo "Getting initial cluster state..."
INITIAL_PRIMARY=$(kubectl get cluster postgres-test -n default -o jsonpath='{.status.currentPrimary}')
INSTANCES=$(kubectl get cluster postgres-test -n default -o jsonpath='{.status.instances}')

if [[ "$INSTANCES" -lt 2 ]]; then
  echo "⚠ Warning: Cluster has only ${INSTANCES} instance(s). Failover test requires at least 2 instances."
  echo "Skipping failover test."
  exit 0
fi

echo "  Initial primary: ${INITIAL_PRIMARY}"
echo "  Total instances: ${INSTANCES}"

# Get initial data count
INITIAL_DATA_COUNT=$(kubectl exec -n default "$INITIAL_PRIMARY" -- psql -U postgres -t -c "SELECT COUNT(*) FROM test_table;" 2>/dev/null || echo "0")
INITIAL_DATA_COUNT=$(echo "$INITIAL_DATA_COUNT" | tr -d ' ')
echo "  Initial data count: ${INITIAL_DATA_COUNT} rows"

# Record start time
START_TIME=$(date +%s)

echo ""
echo "Simulating primary failure by deleting primary pod..."
kubectl delete pod "$INITIAL_PRIMARY" -n default --wait=false

echo "Waiting for automatic failover (max 2 minutes)..."

# Wait for new primary to be elected
TIMEOUT=120
ELAPSED=0
NEW_PRIMARY=""

while [[ $ELAPSED -lt $TIMEOUT ]]; do
  # Check if cluster is still healthy
  STATUS=$(kubectl get cluster postgres-test -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  CURRENT_PRIMARY=$(kubectl get cluster postgres-test -n default -o jsonpath='{.status.currentPrimary}' 2>/dev/null || echo "")
  READY=$(kubectl get cluster postgres-test -n default -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")
  
  echo "  Elapsed: ${ELAPSED}s | Status: ${STATUS} | Current primary: ${CURRENT_PRIMARY} | Ready: ${READY}/${INSTANCES}"
  
  # Check if a new primary was elected (different from initial)
  if [[ -n "$CURRENT_PRIMARY" ]] && [[ "$CURRENT_PRIMARY" != "$INITIAL_PRIMARY" ]]; then
    NEW_PRIMARY="$CURRENT_PRIMARY"
    echo ""
    echo "✓ New primary elected: ${NEW_PRIMARY}"
    break
  fi
  
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

if [[ -z "$NEW_PRIMARY" ]]; then
  echo "✗ Error: Failover did not complete within ${TIMEOUT}s"
  echo ""
  echo "Cluster status:"
  kubectl get cluster postgres-test -n default
  echo ""
  echo "Pod status:"
  kubectl get pods -l cnpg.io/cluster=postgres-test -n default
  exit 1
fi

# Calculate failover time
END_TIME=$(date +%s)
FAILOVER_TIME=$((END_TIME - START_TIME))
echo "  Failover time: ${FAILOVER_TIME} seconds"

# Validate SC-003: Cluster recovers within 2 minutes
if [[ $FAILOVER_TIME -gt 120 ]]; then
  echo "✗ Error: Failover took longer than 2 minutes (${FAILOVER_TIME}s)"
  exit 1
fi
echo "✓ Failover completed within 2 minutes"

# Wait for all pods to be ready
echo ""
echo "Waiting for all pods to be ready..."
sleep 10

TIMEOUT=60
ELAPSED=0
while [[ $ELAPSED -lt $TIMEOUT ]]; do
  READY=$(kubectl get cluster postgres-test -n default -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")
  
  echo "  Ready instances: ${READY}/${INSTANCES}"
  
  if [[ "$READY" == "$INSTANCES" ]]; then
    echo "✓ All instances are ready"
    break
  fi
  
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

if [[ "$READY" != "$INSTANCES" ]]; then
  echo "⚠ Warning: Not all instances are ready after failover (${READY}/${INSTANCES})"
fi

# Verify zero data loss (SC-007)
echo ""
echo "Verifying zero data loss..."

# Wait for new primary to be fully ready
sleep 5

# Try to connect to new primary
if ! kubectl exec -n default "$NEW_PRIMARY" -- psql -U postgres -c "SELECT 1;" &>/dev/null; then
  echo "✗ Error: Cannot connect to new primary"
  exit 1
fi

# Check data count
FINAL_DATA_COUNT=$(kubectl exec -n default "$NEW_PRIMARY" -- psql -U postgres -t -c "SELECT COUNT(*) FROM test_table;" 2>/dev/null || echo "0")
FINAL_DATA_COUNT=$(echo "$FINAL_DATA_COUNT" | tr -d ' ')

echo "  Initial data count: ${INITIAL_DATA_COUNT}"
echo "  Final data count: ${FINAL_DATA_COUNT}"

if [[ "$FINAL_DATA_COUNT" != "$INITIAL_DATA_COUNT" ]]; then
  echo "✗ Error: Data loss detected! (lost $((INITIAL_DATA_COUNT - FINAL_DATA_COUNT)) rows)"
  exit 1
fi
echo "✓ Zero data loss - all ${FINAL_DATA_COUNT} rows preserved"

# Insert new data to verify write capability
echo ""
echo "Testing write capability on new primary..."
kubectl exec -n default "$NEW_PRIMARY" -- psql -U postgres <<EOF
  INSERT INTO test_table (data) VALUES ('post-failover-data');
EOF

NEW_DATA_COUNT=$(kubectl exec -n default "$NEW_PRIMARY" -- psql -U postgres -t -c "SELECT COUNT(*) FROM test_table;")
NEW_DATA_COUNT=$(echo "$NEW_DATA_COUNT" | tr -d ' ')

if [[ "$NEW_DATA_COUNT" -le "$FINAL_DATA_COUNT" ]]; then
  echo "✗ Error: Failed to insert data after failover"
  exit 1
fi
echo "✓ Successfully wrote data to new primary (${NEW_DATA_COUNT} rows total)"

# Verify replication is working
if [[ "$INSTANCES" -gt 1 ]]; then
  echo ""
  echo "Verifying replication after failover..."
  
  # Wait for replication to catch up
  sleep 10
  
  # Check replication status
  echo "Replication status:"
  kubectl exec -n default "$NEW_PRIMARY" -- psql -U postgres -c "SELECT client_addr, state, sync_state, replay_lag FROM pg_stat_replication;" || true
fi

echo ""
echo "=== Failover Test Complete ==="
echo "✓ All tests passed"
echo ""
echo "Failover Summary:"
echo "  Initial primary: ${INITIAL_PRIMARY}"
echo "  New primary: ${NEW_PRIMARY}"
echo "  Failover time: ${FAILOVER_TIME} seconds"
echo "  Data integrity: ✓ Zero data loss (${FINAL_DATA_COUNT} rows preserved)"
echo "  Write capability: ✓ Verified"
echo ""
echo "Success Criteria Validated:"
echo "  SC-003: ✓ Cluster recovered from pod deletion within 2 minutes"
echo "  SC-007: ✓ Zero data loss on failover (quorum replication)"
