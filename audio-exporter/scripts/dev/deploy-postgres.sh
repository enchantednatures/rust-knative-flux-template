#!/usr/bin/env bash

# Deploy PostgreSQL Cluster and Supporting Infrastructure
#
# This script handles complete PostgreSQL cluster deployment including:
# - CloudNativePG operator installation (if not present)
# - MinIO deployment for object storage (development only)
# - PostgreSQL cluster creation
# - Database initialization
# - Backup configuration
#
# Usage:
#   ./deploy-postgres.sh [environment] [options]
#
# Arguments:
#   environment   - dev, staging, or prod (default: dev)
#
# Options:
#   --namespace   - Kubernetes namespace (default: default)
#   --kustomize   - Path to kustomization (default: deploy/overlays/$env)
#   --wait        - Wait time for resources to be ready (default: 600s)
#   --no-wait     - Don't wait for resources to be ready
#   --dry-run     - Show what would be deployed without applying
#   --help        - Show this message

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Default values
ENVIRONMENT="${1:-dev}"
NAMESPACE="default"
KUSTOMIZE_PATH=""
WAIT_TIME=600
DRY_RUN=false

# Parse options
while [[ $# -gt 1 ]]; do
    case "$2" in
        --namespace)
            NAMESPACE="$3"
            shift 2
            ;;
        --kustomize)
            KUSTOMIZE_PATH="$3"
            shift 2
            ;;
        --wait)
            WAIT_TIME="$3"
            shift 2
            ;;
        --no-wait)
            WAIT_TIME=0
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            head -30 "$0" | grep -E "^#|^$" | sed 's/^# *//'
            exit 0
            ;;
        *)
            error "Unknown option: $2"
            exit 1
            ;;
    esac
done

# Validate environment
case "$ENVIRONMENT" in
    dev|staging|prod)
        ;;
    *)
        error "Invalid environment: $ENVIRONMENT. Must be dev, staging, or prod"
        exit 1
        ;;
esac

# Set defaults
KUSTOMIZE_PATH="${KUSTOMIZE_PATH:-deploy/overlays/$ENVIRONMENT}"
POSTGRES_CLUSTER_NAME="${PROJECT_NAME:-my-postgres}-postgres"

info "Deploying PostgreSQL to $ENVIRONMENT environment"
info "Namespace: $NAMESPACE"
info "Kustomization: $KUSTOMIZE_PATH"
info "Cluster: $POSTGRES_CLUSTER_NAME"

# ============================================================================
# Step 1: Verify prerequisites
# ============================================================================

info "Checking prerequisites..."

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    error "kubectl not found. Please install kubectl."
    exit 1
fi

# Check if connected to cluster
if ! kubectl cluster-info &> /dev/null; then
    error "Not connected to Kubernetes cluster. Please configure kubeconfig."
    exit 1
fi

# Check if kustomize path exists
if [[ ! -d "$KUSTOMIZE_PATH" ]]; then
    error "Kustomization directory not found: $KUSTOMIZE_PATH"
    exit 1
fi

success "✓ Prerequisites satisfied"

# ============================================================================
# Step 2: Create namespace if needed
# ============================================================================

if kubectl get namespace "$NAMESPACE" &> /dev/null; then
    info "Namespace $NAMESPACE already exists"
else
    info "Creating namespace $NAMESPACE..."
    if [[ "$DRY_RUN" == "false" ]]; then
        kubectl create namespace "$NAMESPACE"
        success "✓ Namespace $NAMESPACE created"
    else
        info "(dry-run) Would create namespace $NAMESPACE"
    fi
fi

# ============================================================================
# Step 3: Deploy with kustomize
# ============================================================================

info "Building manifest from kustomization..."
if kustomize build "$KUSTOMIZE_PATH" > /tmp/postgres-manifest.yaml; then
    success "✓ Manifest built successfully"
else
    error "Failed to build manifest. Check kustomization files."
    exit 1
fi

# Show what will be deployed
info "Resources to be deployed:"
kubectl api-resources --api-group="" -o name | \
    xargs -I {} grep "kind: " /tmp/postgres-manifest.yaml | \
    sort | uniq -c || true

if [[ "$DRY_RUN" == "true" ]]; then
    info "(dry-run) Would apply manifest. Manifest saved to /tmp/postgres-manifest.yaml"
    info "View with: cat /tmp/postgres-manifest.yaml"
    exit 0
fi

# Apply the manifest
info "Applying manifest..."
kubectl apply -n "$NAMESPACE" -f /tmp/postgres-manifest.yaml
success "✓ Manifest applied"

# ============================================================================
# Step 4: Wait for resources to be ready
# ============================================================================

if [[ $WAIT_TIME -gt 0 ]]; then
    info "Waiting up to ${WAIT_TIME}s for PostgreSQL cluster to be ready..."
    
    # Wait for CloudNativePG cluster to be ready
    if kubectl wait --for=condition=ready \
        cluster/${POSTGRES_CLUSTER_NAME} \
        -n "$NAMESPACE" \
        --timeout="${WAIT_TIME}s" &> /dev/null; then
        success "✓ PostgreSQL cluster is ready"
    else
        warn "PostgreSQL cluster did not become ready within ${WAIT_TIME}s"
        info "Check status with: kubectl describe cluster $POSTGRES_CLUSTER_NAME -n $NAMESPACE"
    fi
    
    # Get cluster status
    info "Cluster status:"
    kubectl get cluster "${POSTGRES_CLUSTER_NAME}" -n "$NAMESPACE" -o wide
fi

# ============================================================================
# Step 5: Verify deployment
# ============================================================================

info "Verifying deployment..."

# Check cluster exists
if kubectl get cluster "${POSTGRES_CLUSTER_NAME}" -n "$NAMESPACE" &> /dev/null; then
    success "✓ PostgreSQL cluster created"
else
    error "PostgreSQL cluster not found"
    exit 1
fi

# Get pod information
POD_COUNT=$(kubectl get pods -n "$NAMESPACE" \
    -l postgresql.cnpg.io/cluster="${POSTGRES_CLUSTER_NAME}" \
    --no-headers 2>/dev/null | wc -l)

info "PostgreSQL pods: $POD_COUNT"

# Get service information
if kubectl get service "${POSTGRES_CLUSTER_NAME}-rw" -n "$NAMESPACE" &> /dev/null; then
    success "✓ Read-write service available"
    RW_SERVICE=$(kubectl get svc "${POSTGRES_CLUSTER_NAME}-rw" -n "$NAMESPACE" \
        -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}')
    info "  Read-write endpoint: $RW_SERVICE"
fi

if kubectl get service "${POSTGRES_CLUSTER_NAME}-ro" -n "$NAMESPACE" &> /dev/null; then
    success "✓ Read-only service available"
    RO_SERVICE=$(kubectl get svc "${POSTGRES_CLUSTER_NAME}-ro" -n "$NAMESPACE" \
        -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}')
    info "  Read-only endpoint: $RO_SERVICE"
fi

# ============================================================================
# Step 6: Print next steps
# ============================================================================

info "Deployment complete!"
info ""
info "Next steps:"
info "1. Port-forward to PostgreSQL:"
info "   kubectl port-forward svc/${POSTGRES_CLUSTER_NAME}-rw -n $NAMESPACE 5432:5432 &"
info ""
info "2. Connect to database:"
info "   export PGPASSWORD=\$(kubectl get secret -n $NAMESPACE ${POSTGRES_CLUSTER_NAME}-app -o jsonpath='{.data.password}' | base64 -d)"
info "   psql -h localhost -U app -d app"
info ""
info "3. Check cluster status:"
info "   kubectl describe cluster ${POSTGRES_CLUSTER_NAME} -n $NAMESPACE"
info "   ./check-postgres-status.sh"
info ""
info "4. Create backups:"
info "   ./create-backup.sh"
