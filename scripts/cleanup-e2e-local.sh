#!/usr/bin/env bash
#
# Cleanup script for local E2E test artifacts
# Removes Kind clusters, local registry, and generated files
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}ℹ ${1}${NC}"
}

log_success() {
    echo -e "${GREEN}✓ ${1}${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠ ${1}${NC}"
}

echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}  E2E Test Cleanup${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""

# Delete Kind clusters
log_info "Deleting Kind clusters..."
for cluster in e2e-no-s3 e2e-with-s3; do
    if kind get clusters 2>/dev/null | grep -q "^${cluster}$"; then
        kind delete cluster --name "${cluster}"
        log_success "Deleted cluster: ${cluster}"
    else
        log_info "Cluster not found: ${cluster}"
    fi
done

# Stop local registry
log_info "Stopping local registry..."
if docker ps -a | grep -q kind-registry-e2e; then
    docker stop kind-registry-e2e 2>/dev/null || true
    docker rm kind-registry-e2e 2>/dev/null || true
    log_success "Removed local registry: kind-registry-e2e"
else
    log_info "Local registry not found"
fi

# Clean up generated files
log_info "Cleaning up generated files..."
rm -rf ./generated/test-app-no-s3
rm -rf ./generated/test-app-with-s3
rm -f template-values-no-s3.toml
rm -f template-values-with-s3.toml
rm -f /tmp/kind-kubeconfig-no-s3
rm -f /tmp/kind-kubeconfig-with-s3

# Remove empty generated directory if it exists
if [ -d "./generated" ] && [ -z "$(ls -A ./generated)" ]; then
    rmdir ./generated
    log_success "Removed empty generated directory"
fi

log_success "Cleanup complete!"
echo ""
echo -e "${GREEN}All E2E test artifacts have been removed.${NC}"
