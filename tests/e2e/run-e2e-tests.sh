#!/usr/bin/env bash

# PostgreSQL E2E Test Suite Runner
#
# Orchestrates and runs all PostgreSQL E2E tests with proper setup/teardown
#
# Usage:
#   ./run-e2e-tests.sh [options]
#
# Options:
#   --help            Show this help message
#   --scenario <name> Scenario name (default: default)
#   --keep-cluster    Keep cluster running after tests complete
#   --verbose         Show all commands and output
#   --tests <list>    Run specific tests (comma-separated, e.g., 08,10)
#   --skip <list>     Skip specific tests (comma-separated)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO="${SCENARIO:-default}"
KEEP_CLUSTER=false
VERBOSE=false
TESTS_TO_RUN=""
TESTS_TO_SKIP=""

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            head -20 "$0" | grep -E "^#|^$" | sed 's/^# *//'
            exit 0
            ;;
        --scenario)
            SCENARIO="$2"
            shift 2
            ;;
        --keep-cluster)
            KEEP_CLUSTER=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            set -x
            shift
            ;;
        --tests)
            TESTS_TO_RUN="$2"
            shift 2
            ;;
        --skip)
            TESTS_TO_SKIP="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Logging functions
info() {
    echo -e "${BLUE}ℹ${NC} $*"
}

success() {
    echo -e "${GREEN}✓${NC} $*"
}

error() {
    echo -e "${RED}✗${NC} $*"
}

warn() {
    echo -e "${YELLOW}⚠${NC} $*"
}

section() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $*${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Track test results
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
FAILED_TESTS=()

# ============================================================================
# Setup
# ============================================================================

section "PostgreSQL E2E Test Suite"

info "Scenario: $SCENARIO"
info "Keep cluster: $KEEP_CLUSTER"
info "Verbose: $VERBOSE"

if [[ -n "$TESTS_TO_RUN" ]]; then
    info "Running tests: $TESTS_TO_RUN"
fi

if [[ -n "$TESTS_TO_SKIP" ]]; then
    info "Skipping tests: $TESTS_TO_SKIP"
fi

# Set kubeconfig for scenario
export KUBECONFIG="${SCRIPT_DIR}/.kubeconfig-${SCENARIO}"

# ============================================================================
# Helper functions
# ============================================================================

should_run_test() {
    local test_num=$1
    
    # Check skip list
    if [[ -n "$TESTS_TO_SKIP" ]]; then
        if echo "$TESTS_TO_SKIP" | grep -q "$test_num"; then
            return 1
        fi
    fi
    
    # Check run list (if specified)
    if [[ -n "$TESTS_TO_RUN" ]]; then
        if echo "$TESTS_TO_RUN" | grep -q "$test_num"; then
            return 0
        else
            return 1
        fi
    fi
    
    return 0
}

run_test() {
    local test_num=$1
    local test_name=$2
    local test_script=$3
    
    section "Test $test_num: $test_name"
    
    if ! should_run_test "$test_num"; then
        warn "Skipping test $test_num"
        ((TESTS_SKIPPED++))
        return 0
    fi
    
    if [[ ! -f "$test_script" ]]; then
        error "Test script not found: $test_script"
        ((TESTS_FAILED++))
        FAILED_TESTS+=("$test_num: $test_name (script not found)")
        return 1
    fi
    
    info "Running: $test_script"
    
    local start_time=$(date +%s)
    
    if bash "$test_script"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        success "Test $test_num completed in ${duration}s"
        ((TESTS_PASSED++))
        return 0
    else
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        error "Test $test_num failed after ${duration}s"
        ((TESTS_FAILED++))
        FAILED_TESTS+=("$test_num: $test_name")
        return 1
    fi
}

# ============================================================================
# Run Tests
# ============================================================================

# Test 08: Deployment
if should_run_test 08; then
    run_test 08 "PostgreSQL Deployment" "$SCRIPT_DIR/08-test-postgres-deployment.sh" || true
else
    ((TESTS_SKIPPED++))
fi

# Test 09: Backup and Restore
if should_run_test 09; then
    run_test 09 "Backup and Restore" "$SCRIPT_DIR/09-test-backup-restore.sh" || true
else
    ((TESTS_SKIPPED++))
fi

# Test 10: Failover
if should_run_test 10; then
    run_test 10 "Failover and High Availability" "$SCRIPT_DIR/10-test-failover.sh" || true
else
    ((TESTS_SKIPPED++))
fi

# ============================================================================
# Cleanup
# ============================================================================

if [[ "$KEEP_CLUSTER" == "false" ]]; then
    section "Cleanup"
    
    info "Cleaning up resources..."
    if [[ -f "$SCRIPT_DIR/99-cleanup.sh" ]]; then
        bash "$SCRIPT_DIR/99-cleanup.sh" || warn "Cleanup script failed (non-fatal)"
    else
        warn "Cleanup script not found: $SCRIPT_DIR/99-cleanup.sh"
    fi
    
    success "Cleanup complete"
else
    info "Keeping cluster running (--keep-cluster specified)"
    info "To clean up manually, run:"
    info "  bash $SCRIPT_DIR/99-cleanup.sh"
fi

# ============================================================================
# Summary
# ============================================================================

section "Test Summary"

info "Tests passed:  ${TESTS_PASSED}"
info "Tests failed:  ${TESTS_FAILED}"
info "Tests skipped: ${TESTS_SKIPPED}"
echo ""

if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
    error "Failed tests:"
    for test in "${FAILED_TESTS[@]}"; do
        echo "  - $test"
    done
    echo ""
    exit 1
else
    success "All tests passed!"
    exit 0
fi
