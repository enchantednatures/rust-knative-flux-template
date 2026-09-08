#!/bin/bash
#
# GitHub Environment Setup Script (Production)
#
# Creates the GitHub 'production' environment with deployment branch
# policies (main + v*) using the GitHub CLI (gh api).
#
# This is a LOCAL-ONLY tool: CI tokens cannot create environments.
# Never wire this script into GitHub Actions workflows.
#
# Usage:
#   make prod-github-env                  (Makefile passes GITHUB_ORG/GITHUB_REPO)
#   GITHUB_ORG=org GITHUB_REPO=repo ./scripts/prod/create-github-env.sh
#   ./scripts/prod/create-github-env.sh --dry-run
#

set -euo pipefail

# Project root (two levels up from this script: scripts/prod/ -> repo root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Configuration
ENVIRONMENT_NAME="production"
DEFAULT_BRANCH_PATTERN="main"
TAG_PATTERN='v*'

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}→${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run]

Creates the GitHub '${ENVIRONMENT_NAME}' environment with deployment
branch policies (${DEFAULT_BRANCH_PATTERN}, ${TAG_PATTERN}) via the GitHub CLI.

Environment variables:
  GITHUB_ORG    GitHub organization (falls back to 'gh repo view' when unset)
  GITHUB_REPO   GitHub repository name (falls back to 'gh repo view' when unset)

Options:
  --dry-run     Print all planned gh api calls without executing anything
  -h, --help    Show this help
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
DRY_RUN=false
for arg in "$@"; do
    case "${arg}" in
        --dry-run)
            DRY_RUN=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown argument: ${arg}"
            usage
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Auth check: fail fast before touching the API
# ---------------------------------------------------------------------------
check_auth() {
    if ! command -v gh &> /dev/null; then
        log_error "GitHub CLI (gh) is not installed"
        log_info "Install it from https://cli.github.com/ then run: gh auth login"
        exit 1
    fi

    if ! gh auth status &> /dev/null; then
        log_error "GitHub CLI (gh) is not authenticated"
        log_info "Please run: gh auth login (with admin access to the repository)"
        exit 1
    fi

    log_success "GitHub CLI authenticated"
}

# ---------------------------------------------------------------------------
# Repo resolution: Makefile-passed env vars first, 'gh repo view' fallback.
# Never derive from 'git remote get-url' (forks/SSH remotes make it fragile).
# ---------------------------------------------------------------------------
resolve_repo() {
    if [[ -n "${GITHUB_ORG:-}" && -n "${GITHUB_REPO:-}" ]]; then
        log_info "Using repository from environment: ${GITHUB_ORG}/${GITHUB_REPO}"
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        # Dry-run must make ZERO network calls: do not invoke 'gh repo view'.
        GITHUB_ORG="${GITHUB_ORG:-<org>}"
        GITHUB_REPO="${GITHUB_REPO:-<repo>}"
        log_warning "GITHUB_ORG/GITHUB_REPO not set — showing placeholders"
        log_info "Preview resolved values via: GITHUB_ORG=<org> GITHUB_REPO=<repo> $(basename "$0") --dry-run"
        return 0
    fi

    log_info "GITHUB_ORG/GITHUB_REPO not set — resolving via 'gh repo view'..."
    local repo_json
    repo_json="$(gh repo view --json owner,name 2>/dev/null)" || {
        log_error "Could not determine the GitHub repository"
        log_info "Set them explicitly: GITHUB_ORG=<org> GITHUB_REPO=<repo> make prod-github-env"
        exit 1
    }
    GITHUB_ORG="$(echo "${repo_json}" | jq -r '.owner.login')"
    GITHUB_REPO="$(echo "${repo_json}" | jq -r '.name')"
    log_info "Resolved repository: ${GITHUB_ORG}/${GITHUB_REPO}"
}

# ---------------------------------------------------------------------------
# Environment creation (idempotent: GET first; 404 -> create)
# ---------------------------------------------------------------------------
ensure_environment() {
    local env_url="/repos/${GITHUB_ORG}/${GITHUB_REPO}/environments/${ENVIRONMENT_NAME}"

    log_info "Checking whether environment '${ENVIRONMENT_NAME}' exists..."
    local out rc
    out="$(gh api "${env_url}" 2>&1)" && rc=0 || rc=$?

    if [[ ${rc} -eq 0 ]]; then
        log_success "Environment '${ENVIRONMENT_NAME}' already exists — skipping creation"
        return 0
    fi

    if [[ "${out}" != *"404"* ]]; then
        log_error "Failed to query environment '${ENVIRONMENT_NAME}' (exit ${rc}):"
        echo "${out}" >&2
        log_info "Check gh auth scopes (repo admin needed) and the org/repo spelling"
        exit 1
    fi

    log_info "Environment not found — creating..."
    out="$(gh api -X POST "${env_url}" \
        -f "deployment_branch_policy[protected_branches]=false" \
        -F "deployment_branch_policy[custom_branch_policies]=true" 2>&1)" && rc=0 || rc=$?

    if [[ ${rc} -ne 0 ]]; then
        # Treat "already exists" races as idempotent success
        if [[ "${out}" == *"409"* || "${out}" == *"422"* ]]; then
            log_success "Environment '${ENVIRONMENT_NAME}' already exists — idempotent success"
            return 0
        fi
        log_error "Failed to create environment '${ENVIRONMENT_NAME}' (exit ${rc}):"
        echo "${out}" >&2
        exit 1
    fi

    log_success "Environment '${ENVIRONMENT_NAME}' created with custom branch policies"
}

# ---------------------------------------------------------------------------
# Deployment branch policies (idempotent: GET list first; a rejected 'v*'
# pattern is NON-FATAL per plan — warn + manual instructions, then continue)
# ---------------------------------------------------------------------------
# Exact-name match against a newline-separated list of existing policies
policy_exists() {
    local pattern="$1"
    local existing="$2"
    [[ $'\n'"${existing}"$'\n' == *$'\n'"${pattern}"$'\n'* ]]
}

add_branch_policy() {
    local pattern="$1"
    local policies_url="$2"
    local existing="$3"

    if policy_exists "${pattern}" "${existing}"; then
        log_success "Branch policy '${pattern}' already exists — skipping"
        return 0
    fi

    log_info "Adding deployment branch policy '${pattern}'..."
    local out rc
    out="$(gh api -X POST "${policies_url}" -f "name=${pattern}" 2>&1)" && rc=0 || rc=$?

    if [[ ${rc} -eq 0 ]]; then
        log_success "Branch policy '${pattern}' added"
        return 0
    fi

    # The tag wildcard pattern may be rejected by the API — non-fatal
    if [[ "${pattern}" == "${TAG_PATTERN}" ]]; then
        log_warning "GitHub rejected the '${pattern}' pattern (exit ${rc}):"
        echo "${out}" >&2
        log_warning "Setup continues — add the tag pattern manually:"
        log_info "  Repo → Settings → Environments → ${ENVIRONMENT_NAME} →"
        log_info "  'Deployment branches and tags' → 'Add deployment tag or branch rule' →"
        log_info "  Ref type: Tag, Name pattern: ${pattern}"
        return 0
    fi

    # Duplicates racing the GET are still idempotent success
    if [[ "${out}" == *"409"* || "${out}" == *"422"* ]]; then
        log_success "Branch policy '${pattern}' already exists — idempotent success"
        return 0
    fi

    log_error "Failed to add branch policy '${pattern}' (exit ${rc}):"
    echo "${out}" >&2
    exit 1
}

ensure_branch_policies() {
    local policies_url="/repos/${GITHUB_ORG}/${GITHUB_REPO}/environments/${ENVIRONMENT_NAME}/deployment-branch-policies"

    log_info "Fetching existing deployment branch policies..."
    local list_out rc existing
    list_out="$(gh api "${policies_url}" 2>&1)" && rc=0 || rc=$?

    if [[ ${rc} -ne 0 ]]; then
        log_error "Failed to list deployment branch policies (exit ${rc}):"
        echo "${list_out}" >&2
        exit 1
    fi

    existing="$(echo "${list_out}" | jq -r '.branch_policies[].name' 2>/dev/null || true)"

    add_branch_policy "${DEFAULT_BRANCH_PATTERN}" "${policies_url}" "${existing}"
    add_branch_policy "${TAG_PATTERN}" "${policies_url}" "${existing}"
}

# ---------------------------------------------------------------------------
# Next steps (secrets are OPERATOR-provided — never created automatically)
# ---------------------------------------------------------------------------
print_next_steps() {
    local env_settings_url="https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/settings/environments"
    echo ""
    echo -e "${GREEN}===================================================================${NC}"
    echo -e "${GREEN}✓ GitHub environment setup complete${NC}"
    echo -e "${GREEN}===================================================================${NC}"
    echo ""
    echo -e "  Environment:  ${GITHUB_ORG}/${GITHUB_REPO} → ${ENVIRONMENT_NAME}"
    echo -e "  Manage:       ${env_settings_url}"
    echo ""
    echo -e "  ${YELLOW}Next steps:${NC}"
    echo -e "  • The deploy workflow targets 'environment: production' — its protection"
    echo -e "    rules (branch policies: ${DEFAULT_BRANCH_PATTERN}, ${TAG_PATTERN}) now gate deployments."
    echo -e "  • Non-ARC deploys (ubuntu-latest) need a 'PROD_KUBECONFIG' environment secret:"
    echo -e "      ${env_settings_url}/${ENVIRONMENT_NAME}"
    echo -e "      → 'Add environment secret' → Name: PROD_KUBECONFIG (paste kubeconfig contents)"
    echo -e "  • ARC runner deploys need no kubeconfig secret (in-cluster ServiceAccount)."
    echo -e "  • CI tokens cannot create environments — never run this from a workflow."
    echo ""
}

# ---------------------------------------------------------------------------
# Dry-run: print every planned call with resolved values; execute nothing
# ---------------------------------------------------------------------------
dry_run() {
    local env_url="/repos/${GITHUB_ORG}/${GITHUB_REPO}/environments/${ENVIRONMENT_NAME}"
    local policies_url="${env_url}/deployment-branch-policies"

    echo ""
    log_info "Dry-run mode — printing planned gh api calls (nothing will execute)"
    echo ""
    echo -e "  ${YELLOW}Target repository:${NC} ${GITHUB_ORG}/${GITHUB_REPO}"
    echo ""
    echo -e "  ${YELLOW}[1/4]${NC} Check environment exists (GET — skip creation on 200):"
    echo "      gh api ${env_url}"
    echo ""
    echo -e "  ${YELLOW}[2/4]${NC} Create environment (POST — only when missing):"
    echo "      gh api -X POST ${env_url} \\"
    echo "          -f deployment_branch_policy[protected_branches]=false \\"
    echo "          -F deployment_branch_policy[custom_branch_policies]=true"
    echo ""
    echo -e "  ${YELLOW}[3/4]${NC} List deployment branch policies (GET — for idempotency):"
    echo "      gh api ${policies_url}"
    echo ""
    echo -e "  ${YELLOW}[4/4]${NC} Add branch policies (POST — only when missing):"
    echo "      gh api -X POST ${policies_url} -f name=main"
    echo "      gh api -X POST ${policies_url} -f name='v*'"
    echo ""
    log_info "A rejected 'v*' pattern is non-fatal: manual-setup guidance is printed and setup continues"
    echo ""
    log_success "Dry-run complete — zero network calls made"
}

# ---------------------------------------------------------------------------
# Main execution
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo "==================================================================="
    echo "GitHub Environment Setup: '${ENVIRONMENT_NAME}'"
    echo "==================================================================="
    echo ""

    if [[ "${DRY_RUN}" == "true" ]]; then
        resolve_repo
        dry_run
        exit 0
    fi

    check_auth
    resolve_repo
    ensure_environment
    ensure_branch_policies
    print_next_steps
}

main "$@"
