#!/bin/bash

# Script: Restore PostgreSQL database from backup
# Purpose: Create a new PostgreSQL cluster restored from a backup or point-in-time
# Usage: ./restore-from-backup.sh [backup-name] [target-time] [new-cluster-name]
#
# Examples:
#   # Restore from specific backup
#   ./restore-from-backup.sh postgres-test-backup-1704326400
#
#   # Point-in-time restore
#   ./restore-from-backup.sh --pitr "2024-01-03 15:30:00"
#
#   # Restore to new cluster name
#   ./restore-from-backup.sh postgres-test-backup-1704326400 postgres-restored

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_NAME="${1:-}"
TARGET_TIME="${2:-}"
NEW_CLUSTER_NAME="${3:-postgres-restored}"
NAMESPACE="${NAMESPACE:-default}"

# Function to show usage
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Restore PostgreSQL database from backup

OPTIONS:
  -b, --backup <name>        Name of backup to restore from
  -t, --target-time <time>   Point-in-time restore (format: YYYY-MM-DD HH:MM:SS UTC)
  -n, --name <name>          New cluster name (default: postgres-restored)
  -s, --namespace <ns>       Kubernetes namespace (default: default)
  -h, --help                 Show this help

EXAMPLES:
  # Restore from latest backup
  $0 -b postgres-test-backup-1704326400

  # Point-in-time restore
  $0 -t "2024-01-03 15:30:00"

  # Restore to custom cluster name
  $0 -b postgres-test-backup-1704326400 -n my-restored-cluster
EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -b|--backup)
            BACKUP_NAME="$2"
            shift 2
            ;;
        -t|--target-time)
            TARGET_TIME="$2"
            shift 2
            ;;
        -n|--name)
            NEW_CLUSTER_NAME="$2"
            shift 2
            ;;
        -s|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

echo "=== PostgreSQL Restore from Backup ==="
echo "New Cluster Name: $NEW_CLUSTER_NAME"
echo "Namespace: $NAMESPACE"

if [ -n "$BACKUP_NAME" ]; then
    echo "Backup Name: $BACKUP_NAME"
elif [ -n "$TARGET_TIME" ]; then
    echo "Point-in-Time Restore: $TARGET_TIME"
else
    echo "Error: Either --backup or --target-time is required"
    usage
fi

echo ""

# Determine restore configuration
if [ -n "$BACKUP_NAME" ]; then
    # Restore from specific backup
    echo "Restoring from backup: $BACKUP_NAME"
    
    BOOTSTRAP_SPEC=$(cat <<'EOF'
    bootstrap:
      recovery:
        method: object_store
        object_store:
          name: postgres-backup-store  # Reference to ObjectStore CRD
        backupId: BACKUP_NAME_PLACEHOLDER
EOF
    )
    BOOTSTRAP_SPEC=${BOOTSTRAP_SPEC//BACKUP_NAME_PLACEHOLDER/$BACKUP_NAME}
else
    # Point-in-time restore
    echo "Performing point-in-time restore to: $TARGET_TIME"
    
    # Convert timestamp to Unix timestamp
    TARGET_TIMESTAMP=$(date -j -f "%Y-%m-%d %H:%M:%S" "$TARGET_TIME UTC" +"%s" 2>/dev/null || \
                      date -d "$TARGET_TIME UTC" +"%s" 2>/dev/null || \
                      echo "")
    
    if [ -z "$TARGET_TIMESTAMP" ]; then
        echo "Error: Could not parse target time: $TARGET_TIME"
        echo "Use format: YYYY-MM-DD HH:MM:SS UTC"
        exit 1
    fi
    
    BOOTSTRAP_SPEC=$(cat <<'EOF'
    bootstrap:
      recovery:
        method: object_store
        object_store:
          name: postgres-backup-store  # Reference to ObjectStore CRD
        recoveryTarget:
          targetTimeline: latest
          targetXid: null
          targetName: null
          # If you have a specific WAL file or LSN, uncomment:
          # targetLSN: "0/12345678"
          targetTime: "TARGET_TIME_PLACEHOLDER"
          exclusive: false
EOF
    )
    BOOTSTRAP_SPEC=${BOOTSTRAP_SPEC//TARGET_TIME_PLACEHOLDER/$TARGET_TIME}
fi

# Create restore cluster manifest
echo "Creating restore cluster manifest..."

kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $NEW_CLUSTER_NAME
  namespace: $NAMESPACE
spec:
  instances: 1  # Start with single instance for restore verification
  
  # Source cluster from external backup
  externalClusters:
    - name: source
      connectionParameters:
        host: postgres-app-rw.default.svc.cluster.local
        user: postgres
        dbname: postgres
  
  # Recovery/Restore bootstrap configuration
  $BOOTSTRAP_SPEC
  
  # PostgreSQL version (should match source cluster)
  postgresql:
    version: "16"
    parameters:
      # Restore configuration
      shared_buffers: "256Mi"
      max_connections: "100"
  
  # Resources for restore (can be scaled after verification)
  resources:
    requests:
      cpu: "500m"
      memory: "512Mi"
    limits:
      cpu: "1"
      memory: "1Gi"
  
  # Storage for restored database
  storage:
    size: "20Gi"
  
  # Monitoring (optional, enable after restore verified)
  monitoring:
    enabled: false
EOF

echo "✓ Restore cluster manifest created"
echo ""
echo "Waiting for restore cluster to initialize..."

# Wait for cluster to reach target phase
echo "Waiting up to 600 seconds for restore to complete..."

START_TIME=$(date +%s)
TIMEOUT=600

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    
    if [ $ELAPSED -gt $TIMEOUT ]; then
        echo "✗ Restore timeout exceeded"
        kubectl describe cluster "$NEW_CLUSTER_NAME" -n "$NAMESPACE"
        exit 1
    fi
    
    # Check cluster phase
    PHASE=$(kubectl get cluster "$NEW_CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    READY=$(kubectl get cluster "$NEW_CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")
    
    if [ "$PHASE" = "Cluster in healthy state" ] || [ "$READY" = "1" ]; then
        echo "✓ Restore cluster is healthy"
        break
    fi
    
    echo "  Status: $PHASE | Ready instances: $READY | Elapsed: ${ELAPSED}s"
    sleep 10
done

echo ""
echo "=== Restore Verification ==="

# Get restored cluster details
echo "Restored cluster details:"
kubectl get cluster "$NEW_CLUSTER_NAME" -n "$NAMESPACE" -o wide

echo ""
echo "Connecting to restored cluster for verification..."

# Find restored pod
RESTORED_POD=$(kubectl get pod -n "$NAMESPACE" -l postgresql="$NEW_CLUSTER_NAME",role=primary -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$RESTORED_POD" ]; then
    echo "⚠ Warning: Could not find restored cluster pod"
    echo "Cluster may still be initializing"
else
    echo "Restored primary pod: $RESTORED_POD"
    
    # Verify restored data
    echo ""
    echo "Verifying restored data..."
    
    # List databases
    echo "Databases in restored cluster:"
    kubectl exec -it "$RESTORED_POD" -n "$NAMESPACE" -- psql -U postgres -c "\\l" || echo "Could not list databases"
    
    # Check table count in restored database
    echo ""
    echo "Tables in restored 'app' database:"
    kubectl exec -it "$RESTORED_POD" -n "$NAMESPACE" -- psql -U postgres -d app -c "\\dt" 2>/dev/null || echo "Database 'app' not found or not restored yet"
fi

echo ""
echo "=== Restore Complete ==="
echo ""
echo "Next steps:"
echo "1. Verify data integrity in restored cluster"
echo "2. Run queries against restored database"
echo "3. Once verified, scale cluster: kubectl scale cluster $NEW_CLUSTER_NAME --replicas=3"
echo "4. Set up replication and backups for restored cluster"
echo ""
echo "To connect to restored cluster:"
echo "  kubectl port-forward svc/$NEW_CLUSTER_NAME-rw 5432:5432"
echo "  psql -h localhost -U postgres -d app"
echo ""
echo "To delete restored cluster when done:"
echo "  kubectl delete cluster $NEW_CLUSTER_NAME -n $NAMESPACE"
