#!/usr/bin/env bash

# Check PostgreSQL Cluster Status and Health
#
# Provides comprehensive status information for a PostgreSQL cluster including:
# - Cluster health and readiness
# - Pod status and replication
# - Instance information and roles
# - Connection statistics
# - Storage usage
#
# Usage:
#   ./check-postgres-status.sh [cluster-name] [namespace]
#
# Arguments:
#   cluster-name  - Name of PostgreSQL cluster (default: my-postgres-postgres)
#   namespace     - Kubernetes namespace (default: default)

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Default values
CLUSTER_NAME="${1:-my-postgres-postgres}"
NAMESPACE="${2:-default}"

info "Checking PostgreSQL cluster status: $CLUSTER_NAME"
info "Namespace: $NAMESPACE"
info ""

# ============================================================================
# Verify cluster exists
# ============================================================================

if ! kubectl get cluster "$CLUSTER_NAME" -n "$NAMESPACE" &> /dev/null; then
    error "Cluster not found: $CLUSTER_NAME in namespace $NAMESPACE"
    exit 1
fi

# ============================================================================
# Cluster Status
# ============================================================================

section "CLUSTER STATUS"

kubectl get cluster "$CLUSTER_NAME" -n "$NAMESPACE" -o wide

info ""
info "Detailed cluster information:"
kubectl describe cluster "$CLUSTER_NAME" -n "$NAMESPACE" | \
    grep -E "Status:|Instances:|Phase:|Message:|Current Primary:|Ready:" | \
    sed 's/^/  /'

# ============================================================================
# Pod Status
# ============================================================================

section "POD STATUS"

PODS=$(kubectl get pods -n "$NAMESPACE" \
    -l postgresql.cnpg.io/cluster="$CLUSTER_NAME" \
    -o wide)

if [[ -z "$PODS" ]]; then
    warn "No pods found for cluster $CLUSTER_NAME"
else
    kubectl get pods -n "$NAMESPACE" \
        -l postgresql.cnpg.io/cluster="$CLUSTER_NAME" \
        -o wide
fi

# ============================================================================
# Replica Status
# ============================================================================

section "REPLICATION STATUS"

# Get primary pod
PRIMARY_POD=$(kubectl get pods -n "$NAMESPACE" \
    -l postgresql.cnpg.io/cluster="$CLUSTER_NAME",cnpg.io/podRole=primary \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$PRIMARY_POD" ]]; then
    warn "No primary pod found"
else
    info "Primary: $PRIMARY_POD"
    
    # Try to get replication status
    if kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -- \
        psql -U postgres -d postgres -c \
        "SELECT slot_name, slot_type, active, restart_lsn FROM pg_replication_slots;" \
        2>/dev/null || true; then
        :
    else
        warn "Could not query replication slots (database may not be ready yet)"
    fi
fi

# Get replica pods
REPLICA_PODS=$(kubectl get pods -n "$NAMESPACE" \
    -l postgresql.cnpg.io/cluster="$CLUSTER_NAME",cnpg.io/podRole=replica \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

if [[ -n "$REPLICA_PODS" ]]; then
    info "Replicas: $REPLICA_PODS"
else
    info "No replica pods found (cluster may have 1 instance)"
fi

# ============================================================================
# Services
# ============================================================================

section "SERVICES"

RW_SERVICE="${CLUSTER_NAME}-rw"
RO_SERVICE="${CLUSTER_NAME}-ro"
R_SERVICE="${CLUSTER_NAME}-r"

for svc in $RW_SERVICE $RO_SERVICE $R_SERVICE; do
    if kubectl get service "$svc" -n "$NAMESPACE" &> /dev/null; then
        info "Service: $svc"
        CLUSTER_IP=$(kubectl get svc "$svc" -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')
        PORT=$(kubectl get svc "$svc" -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].port}')
        info "  Endpoint: $CLUSTER_IP:$PORT"
    fi
done

# ============================================================================
# Storage
# ============================================================================

section "STORAGE"

kubectl get persistentvolumeclaims -n "$NAMESPACE" \
    -l postgresql.cnpg.io/cluster="$CLUSTER_NAME" \
    -o wide 2>/dev/null || info "No persistent volume claims found"

# ============================================================================
# Backups
# ============================================================================

section "BACKUP STATUS"

# Check for ScheduledBackup
SCHEDULED_BACKUP="${CLUSTER_NAME}-daily-backup"
if kubectl get scheduledbackup "$SCHEDULED_BACKUP" -n "$NAMESPACE" &> /dev/null 2>&1; then
    info "Scheduled backup found: $SCHEDULED_BACKUP"
    kubectl get scheduledbackup "$SCHEDULED_BACKUP" -n "$NAMESPACE" -o wide
else
    info "No scheduled backup found for this cluster"
fi

# Check for recent backups
info ""
info "Recent backups:"
kubectl get backup -n "$NAMESPACE" \
    -l postgresql.cnpg.io/cluster="$CLUSTER_NAME" \
    --sort-by=.metadata.creationTimestamp \
    -o wide 2>/dev/null | tail -5 || info "  No backups found"

# ============================================================================
# Events
# ============================================================================

section "RECENT EVENTS"

kubectl get events -n "$NAMESPACE" \
    --field-selector involvedObject.kind=Cluster,involvedObject.name="$CLUSTER_NAME" \
    --sort-by='.lastTimestamp' | tail -10 || true

# ============================================================================
# Summary
# ============================================================================

section "HEALTH SUMMARY"

# Count ready pods
TOTAL_PODS=$(kubectl get pods -n "$NAMESPACE" \
    -l postgresql.cnpg.io/cluster="$CLUSTER_NAME" \
    --no-headers | wc -l)

READY_PODS=$(kubectl get pods -n "$NAMESPACE" \
    -l postgresql.cnpg.io/cluster="$CLUSTER_NAME" \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | \
    grep -c "True" || echo "0")

info "Total pods: $TOTAL_PODS"
info "Ready pods: $READY_PODS"

if [[ "$TOTAL_PODS" -eq "$READY_PODS" && "$TOTAL_PODS" -gt 0 ]]; then
    success "✓ Cluster is healthy"
else
    warn "⚠ Cluster is not yet healthy (waiting for pods)"
fi

info ""
info "For more details, run:"
info "  kubectl describe cluster $CLUSTER_NAME -n $NAMESPACE"
info "  kubectl logs -n $NAMESPACE [pod-name]"
