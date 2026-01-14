#!/bin/bash
set -e

# Script: Create manual PostgreSQL backup
# Purpose: Trigger an ad-hoc backup for PostgreSQL cluster
# Usage: ./create-backup.sh [cluster-name] [namespace]

CLUSTER_NAME="${1:-postgres-app}"
NAMESPACE="${2:-default}"
BACKUP_NAME="${CLUSTER_NAME}-backup-$(date +%s)"

echo "Creating manual backup: $BACKUP_NAME"
echo "Cluster: $CLUSTER_NAME"
echo "Namespace: $NAMESPACE"

# Create Backup CRD (ad-hoc backup)
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $BACKUP_NAME
  namespace: $NAMESPACE
spec:
  cluster:
    name: $CLUSTER_NAME
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
    parameters:
      barmanObjectName: postgres-backup-store
  target: prefer-standby
EOF

echo "Backup job created: $BACKUP_NAME"
echo ""
echo "Waiting for backup to start..."
sleep 5

# Wait for backup to complete
echo "Monitoring backup progress..."
for i in {1..300}; do
  STATUS=$(kubectl get backup "$BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [ "$STATUS" = "completed" ]; then
    echo "✓ Backup completed successfully!"
    kubectl get backup "$BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status}'
    break
  elif [ "$STATUS" = "failed" ]; then
    echo "✗ Backup failed!"
    kubectl describe backup "$BACKUP_NAME" -n "$NAMESPACE"
    exit 1
  fi
  
  if [ $((i % 10)) -eq 0 ]; then
    echo "  Still running... ($((i/2)) seconds elapsed)"
  fi
  sleep 2
done

echo ""
echo "Backup Details:"
kubectl get backup "$BACKUP_NAME" -n "$NAMESPACE" -o yaml | grep -E "^  (phase|startedAt|stoppedAt|dataBackupPath):" || true
