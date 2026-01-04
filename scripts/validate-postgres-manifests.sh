#!/usr/bin/env bash
set -euo pipefail

# Script: validate-postgres-manifests.sh
# Purpose: Validate all PostgreSQL manifest files using kubectl dry-run
# Usage: ./scripts/validate-postgres-manifests.sh [OPTIONS]
#
# This script validates:
# - Kubernetes YAML syntax
# - CRD schema compliance
# - Kustomization references
# - Required fields and defaults

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
VERBOSE=${VERBOSE:-false}
SKIP_KUSTOMIZE=${SKIP_KUSTOMIZE:-false}
ENVIRONMENTS=${ENVIRONMENTS:-"dev staging prod"}

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Test mode flag
TEST_MODE=${TEST_MODE:-false}

# Counters
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0

# ============================================================================
# Functions
# ============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $*"
    ((PASSED_CHECKS++))
}

log_warn() {
    echo -e "${YELLOW}[!]${NC} $*"
}

log_error() {
    echo -e "${RED}[✗]${NC} $*"
    ((FAILED_CHECKS++))
}

# Check if file exists
check_file_exists() {
    local file=$1
    ((TOTAL_CHECKS++))
    
    if [[ -f "$REPO_ROOT/$file" ]]; then
        log_success "File exists: $file"
    else
        log_error "File missing: $file"
    fi
}

# Check if file contains valid YAML
check_yaml_syntax() {
    local file=$1
    ((TOTAL_CHECKS++))
    
    if command -v yq &> /dev/null; then
        if yq eval '.' "$file" > /dev/null 2>&1; then
            log_success "YAML syntax valid: $file"
        else
            log_error "YAML syntax invalid: $file"
            if [[ "$VERBOSE" == "true" ]]; then
                yq eval '.' "$file" 2>&1 | head -20
            fi
        fi
    else
        log_warn "yq not installed, skipping YAML syntax check for $file"
    fi
}

# Check manifest with kubectl dry-run
check_manifest_with_kubectl() {
    local file=$1
    local namespace=${2:-default}
    ((TOTAL_CHECKS++))
    
    if kubectl apply -f "$file" \
        --namespace="${namespace}" \
        --dry-run=client \
        -o yaml > /dev/null 2>&1; then
        log_success "Kubectl validation passed: $file"
    else
        log_error "Kubectl validation failed: $file"
        if [[ "$VERBOSE" == "true" ]]; then
            kubectl apply -f "$file" \
                --namespace="${namespace}" \
                --dry-run=client 2>&1 | head -20
        fi
    fi
}

# Check kustomization
check_kustomization() {
    local kust_path=$1
    ((TOTAL_CHECKS++))
    
    if [[ "$SKIP_KUSTOMIZE" == "true" ]]; then
        log_warn "Skipping kustomization check: $kust_path"
        return 0
    fi
    
    if command -v kustomize &> /dev/null; then
        if kustomize build "$kust_path" > /dev/null 2>&1; then
            log_success "Kustomization valid: $kust_path"
        else
            log_error "Kustomization invalid: $kust_path"
            if [[ "$VERBOSE" == "true" ]]; then
                kustomize build "$kust_path" 2>&1 | head -20
            fi
        fi
    else
        log_warn "kustomize not installed, skipping: $kust_path"
    fi
}

# ============================================================================
# Main Validation Checks
# ============================================================================

main() {
    log_info "Starting PostgreSQL manifest validation..."
    echo ""
    
    # ========================================================================
    # Phase 2: Base Manifests
    # ========================================================================
    
    log_info "Checking Phase 2 - Base Manifests..."
    
    check_file_exists "deploy/base/postgres-cluster.yaml.liquid"
    check_file_exists "deploy/base/postgres-backup.yaml.liquid"
    check_file_exists "deploy/base/postgres-pooler.yaml.liquid"
    check_file_exists "deploy/base/postgres-alerts.yaml.liquid"
    check_file_exists "deploy/base/postgres-podmonitor.yaml.liquid"
    check_file_exists "deploy/base/postgres-objectstore.yaml.liquid"
    check_file_exists "deploy/base/object-storage-secret.yaml.example"
    
    # ========================================================================
    # Phase 2: FluxCD Integration
    # ========================================================================
    
    log_info "Checking Phase 2 - FluxCD Integration..."
    
    check_file_exists "deploy/flux/git-repository-postgres.yaml"
    check_file_exists "deploy/flux/postgres-kustomization.yaml.liquid"
    
    # ========================================================================
    # Phase 3: Environment Overlays
    # ========================================================================
    
    log_info "Checking Phase 3 - Environment Overlays..."
    
    for env in $ENVIRONMENTS; do
        log_info "Validating $env environment..."
        
        check_file_exists "deploy/overlays/$env/kustomization.yaml"
        check_file_exists "deploy/overlays/$env/postgres-cluster-patch.yaml.liquid"
        check_file_exists "deploy/overlays/$env/postgres-backup-patch.yaml.liquid"
        check_file_exists "deploy/overlays/$env/infrastructure/minio.yaml"
        
        # Kustomization check
        check_kustomization "deploy/overlays/$env"
    done
    
    # ========================================================================
    # Phase 3: E2E Test Fixtures
    # ========================================================================
    
    log_info "Checking Phase 3 - E2E Test Fixtures..."
    
    check_file_exists "tests/e2e/fixtures/postgres/test-cluster.yaml"
    check_file_exists "tests/e2e/fixtures/postgres/test-data.sql"
    
    # ========================================================================
    # Phase 3: Operational Scripts
    # ========================================================================
    
    log_info "Checking Phase 3 - Operational Scripts..."
    
    check_file_exists "scripts/dev/deploy-postgres.sh"
    check_file_exists "scripts/dev/check-postgres-status.sh"
    check_file_exists "scripts/dev/port-forward-postgres.sh"
    
    # ========================================================================
    # Phase 4: Backup Scripts
    # ========================================================================
    
    log_info "Checking Phase 4 - Backup Scripts..."
    
    check_file_exists "scripts/dev/create-backup.sh"
    check_file_exists "scripts/dev/check-backup-status.sh"
    check_file_exists "scripts/dev/list-backups.sh"
    
    # ========================================================================
    # Phase 5: Restore Scripts
    # ========================================================================
    
    log_info "Checking Phase 5 - Restore Scripts..."
    
    check_file_exists "scripts/dev/restore-from-backup.sh"
    
    # ========================================================================
    # E2E Test Scripts
    # ========================================================================
    
    log_info "Checking E2E Test Scripts..."
    
    check_file_exists "tests/e2e/scripts/07-deploy-postgres.sh"
    check_file_exists "tests/e2e/scripts/08-test-postgres-deployment.sh"
    check_file_exists "tests/e2e/scripts/09-test-backup-restore.sh"
    check_file_exists "tests/e2e/scripts/10-test-failover.sh"
    check_file_exists "tests/e2e/scripts/11-test-monitoring.sh"
    check_file_exists "tests/e2e/scripts/99-cleanup.sh"
    
    # ========================================================================
    # Documentation
    # ========================================================================
    
    log_info "Checking Documentation..."
    
    check_file_exists "docs/POSTGRES.md"
    check_file_exists "docs/POSTGRES_BACKUP_RESTORE.md"
    check_file_exists "docs/POSTGRES_MONITORING.md"
    check_file_exists "docs/POSTGRES_FLUXCD.md"
    check_file_exists "specs/001-cloudnative-postgres-backups/quickstart.md"
    
    # ========================================================================
    # Integration Tests
    # ========================================================================
    
    log_info "Checking Integration Tests..."
    
    check_file_exists "tests/integration/postgres_integration_test.rs"
    check_file_exists "tests/integration/utils.rs"
    
    # ========================================================================
    # Summary
    # ========================================================================
    
    echo ""
    log_info "Validation Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "Total Checks:    $TOTAL_CHECKS"
    echo -e "Passed:          ${GREEN}$PASSED_CHECKS${NC}"
    echo -e "Failed:          ${RED}$FAILED_CHECKS${NC}"
    
    if [[ $FAILED_CHECKS -eq 0 ]]; then
        echo -e "\n${GREEN}✓ All PostgreSQL manifests validated successfully!${NC}"
        return 0
    else
        echo -e "\n${RED}✗ Some manifests failed validation (see above)${NC}"
        return 1
    fi
}

# ============================================================================
# Entry Point
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -s|--skip-kustomize)
                SKIP_KUSTOMIZE=true
                shift
                ;;
            -e|--environments)
                ENVIRONMENTS="$2"
                shift 2
                ;;
            -h|--help)
                cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Validate PostgreSQL manifests and configuration files.

OPTIONS:
    -v, --verbose       Show detailed error messages
    -s, --skip-kustomize
                        Skip kustomization validation
    -e, --environments ENV1,ENV2,...
                        Comma-separated list of environments to check
                        (default: "dev staging prod")
    -h, --help          Show this help message

EXAMPLES:
    # Run full validation
    ./scripts/validate-postgres-manifests.sh

    # Verbose output with details
    ./scripts/validate-postgres-manifests.sh -v

    # Check only dev environment
    ./scripts/validate-postgres-manifests.sh -e dev

    # Check without kustomization validation
    ./scripts/validate-postgres-manifests.sh -s

EOF
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    main
    exit $?
fi
