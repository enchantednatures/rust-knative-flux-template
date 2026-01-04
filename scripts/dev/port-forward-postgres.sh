#!/usr/bin/env bash

# Port-Forward PostgreSQL Service
#
# Exposes PostgreSQL cluster on localhost:5432 for local development
#
# Usage:
#   ./port-forward-postgres.sh [cluster-name] [namespace] [local-port]
#
# Arguments:
#   cluster-name  - Name of PostgreSQL cluster (default: my-postgres-postgres)
#   namespace     - Kubernetes namespace (default: default)
#   local-port    - Local port to forward to (default: 5432)
#
# Examples:
#   # Forward default cluster to localhost:5432
#   ./port-forward-postgres.sh
#
#   # Forward specific cluster to localhost:6432
#   ./port-forward-postgres.sh my-postgres-postgres default 6432
#
#   # Run in background
#   ./port-forward-postgres.sh &
#   export POSTGRES_HOST=localhost POSTGRES_PORT=5432

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Default values
CLUSTER_NAME="${1:-my-postgres-postgres}"
NAMESPACE="${2:-default}"
LOCAL_PORT="${3:-5432}"
SERVICE_NAME="${CLUSTER_NAME}-rw"  # Use read-write service

info "Setting up port-forward for PostgreSQL"
info "Cluster: $CLUSTER_NAME"
info "Namespace: $NAMESPACE"
info "Service: $SERVICE_NAME"
info "Local port: $LOCAL_PORT"
info ""

# ============================================================================
# Verify prerequisites
# ============================================================================

# Check if service exists
if ! kubectl get service "$SERVICE_NAME" -n "$NAMESPACE" &> /dev/null; then
    error "Service not found: $SERVICE_NAME in namespace $NAMESPACE"
    info "Make sure the PostgreSQL cluster is deployed first:"
    info "  ./deploy-postgres.sh"
    exit 1
fi

# Check if port is available
if lsof -Pi :$LOCAL_PORT -sTCP:LISTEN -t >/dev/null ; then
    warn "Port $LOCAL_PORT is already in use"
    info "The port-forward may fail. You can use a different port:"
    info "  ./port-forward-postgres.sh $CLUSTER_NAME $NAMESPACE $((LOCAL_PORT + 1))"
fi

# ============================================================================
# Setup port-forward
# ============================================================================

info "Starting port-forward..."
info "Press Ctrl+C to stop"
info ""
info "Connection details for client:"
info "  Host:     localhost"
info "  Port:     $LOCAL_PORT"
info "  Username: app"
info "  Database: app"
info ""
info "Connect with:"
info "  psql -h localhost -p $LOCAL_PORT -U app -d app"
info ""

# Start port-forward with error handling
if ! kubectl port-forward svc/"$SERVICE_NAME" -n "$NAMESPACE" "$LOCAL_PORT:5432"; then
    error "Port-forward failed"
    info "Debug: Check service status with:"
    info "  kubectl get svc $SERVICE_NAME -n $NAMESPACE"
    info "  ./check-postgres-status.sh"
    exit 1
fi
