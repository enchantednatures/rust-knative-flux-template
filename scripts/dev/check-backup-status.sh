#!/bin/bash

# Script: Check PostgreSQL backup status
# Purpose: Display status of all backups and scheduled backups
# Usage: ./check-backup-status.sh [namespace]

NAMESPACE="${1:-default}"

echo "=== PostgreSQL Scheduled Backups ==="
kubectl get schedulebackup -n "$NAMESPACE" -o wide 2>/dev/null || echo "No scheduled backups found"

echo ""
echo "=== PostgreSQL Manual Backups ==="
kubectl get backup -n "$NAMESPACE" -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,STARTTIME:.status.startedAt,ENDTIME:.status.stoppedAt,SIZE:.status.backupSize 2>/dev/null || echo "No backups found"

echo ""
echo "=== ObjectStore Configuration ==="
kubectl get objectstore -n "$NAMESPACE" -o wide 2>/dev/null || echo "No object storage configured"

echo ""
echo "=== Recent Backup Job Details ==="
LATEST_BACKUP=$(kubectl get backup -n "$NAMESPACE" --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)

if [ -n "$LATEST_BACKUP" ]; then
  echo "Latest backup: $LATEST_BACKUP"
  echo ""
  kubectl describe backup "$LATEST_BACKUP" -n "$NAMESPACE" 2>/dev/null | grep -E "^(Name|Phase|Started|Stopped|Data Backup Path):" || true
else
  echo "No backups found"
fi

echo ""
echo "=== WAL Archiving Status ==="
# Check if any backups are archiving WAL files
kubectl logs -l postgresql=postgres-app,role=primary -n "$NAMESPACE" --tail=50 2>/dev/null | grep -i "wal\|archive" | tail -10 || echo "No WAL archiving logs found"
