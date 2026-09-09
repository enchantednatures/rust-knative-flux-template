#!/bin/bash
#
# Deploy-key / GitRepository provisioning helper (shared library)
#
# Extracted from scripts/prod/deploy.sh so the flow can be reused from:
#   - scripts/prod/deploy.sh          (sources this file)
#   - make bootstrap / make deploy-key (runs this file standalone)
#
# What it does (idempotent, safe to re-run):
#   1. Applies deploy/flux/git-repository.yaml (server-side apply)
#   2. Waits for the GitRepository to become Ready (bounded re-poll; the
#      conditions are inspected after every failed attempt)
#   3. On auth failure: creates the github-deploy-key secret via
#      `flux create secret git` — NEVER rotating an existing secret —
#      prints the public key + GitHub instructions, then keeps polling
#      while the key is added (up to ~5 minutes).
#
# This script NEVER rotates an existing github-deploy-key secret.
#
# Usage:
#   ./scripts/prod/deploy-key.sh            (apply + wait + key flow)
#   ./scripts/prod/deploy-key.sh --dry-run  (print the plan, touch nothing)
#   source scripts/prod/deploy-key.sh       (use the functions from deploy.sh)
#
# Environment:
#   KUBECONFIG         ambient kubeconfig (no own kubeconfig resolution)
#   PROJECT_NAME       override service name (default: parsed from Makefile)
#   GITHUB_REPO_SSH    SSH URL override (default: parsed from git-repository.yaml)
#   DEPLOY_KEY_SECRET  deploy-key secret name (default: github-deploy-key)
#   FLUX_NAMESPACE     Flux namespace (default: flux-system)
#
# Exit codes:
#   0 success · 1 any provisioning failure (with diagnostics)
#

set -euo pipefail

# Project root (two levels up from this script: scripts/prod/ -> repo root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Deploy-key state (defaults only — a sourcing script may pre-set these)
: "${DEPLOY_KEY_SECRET:=github-deploy-key}"
: "${FLUX_NAMESPACE:=flux-system}"
: "${GITREPO_POLL_ATTEMPTS:=6}"    # 6 x 30s kubectl wait = 3m initial wait
: "${GITREPO_POLL_WAIT:=30s}"
: "${DEPLOY_KEY_POLL_ATTEMPTS:=20}" # 20 x 15s kubectl wait = 5m max
: "${DEPLOY_KEY_POLL_WAIT:=15s}"

# Colors + log helpers (skipped when sourced from deploy.sh, which defines
# identical helpers before sourcing this file)
if [[ -z "${BLUE:-}" ]]; then
	RED='\033[0;31m'
	GREEN='\033[0;32m'
	YELLOW='\033[1;33m'
	BLUE='\033[0;34m'
	NC='\033[0m' # No Color
fi

if ! declare -F log_info >/dev/null 2>&1; then
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
fi

# ---------------------------------------------------------------------------
# Name / URL resolution (pure file work — no cluster access, dry-run safe)
# ---------------------------------------------------------------------------
# Kubernetes names must be DNS-subdomain-safe; never auto-mangle a bad name.
validate_project_name() {
	local k8s_name_re='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
	if ! [[ "${PROJECT_NAME}" =~ ${k8s_name_re} ]]; then
		log_error "Resolved PROJECT_NAME '${PROJECT_NAME}' is not a valid Kubernetes name"
		log_error "(must match ^[a-z0-9]([-a-z0-9]*[a-z0-9])?\$ — lowercase alphanumerics and hyphens)"
		log_error "Set the PROJECT_NAME environment variable explicitly and re-run."
		exit 1
	fi
}

# PROJECT_NAME: env override → Makefile (baked at generation time) → basename.
resolve_project_name() {
	if [[ -n "${PROJECT_NAME:-}" ]]; then
		return 0
	fi

	local candidate=""
	if [[ -f "${PROJECT_ROOT}/Makefile" ]]; then
		local line
		line="$(grep -m1 '^PROJECT_NAME' "${PROJECT_ROOT}/Makefile" || true)"
		candidate="${line#*=}"
		candidate="$(echo "${candidate}" | xargs)" # trim whitespace
	fi

	# Adjacent-brace marker built at runtime: this file is itself processed by
	# cargo-generate, so literal brace pairs in it would break template generation.
	local liq_start
	liq_start="$(printf '%s%s' '{' '{')"

	if [[ -n "${candidate}" && "${candidate}" != *"${liq_start}"* ]]; then
		PROJECT_NAME="${candidate}"
	else
		# Template context (liquid not yet rendered) or no Makefile — best effort.
		PROJECT_NAME="$(basename "${PROJECT_ROOT}")"
		validate_project_name
	fi
}

# GITHUB_REPO_SSH: env override → git-repository.yaml → placeholder.
resolve_github_repo_ssh() {
	if [[ -n "${GITHUB_REPO_SSH:-}" ]]; then
		return 0
	fi

	local gr="${PROJECT_ROOT}/deploy/flux/git-repository.yaml"
	if [[ -f "${gr}" ]]; then
		local url liq_start
		liq_start="$(printf '%s%s' '{' '{')"
		url="$(grep -E '^[[:space:]]*url:[[:space:]]*ssh://' "${gr}" | head -1 | awk '{print $2}' || true)"
		if [[ -n "${url}" && "${url}" != *"${liq_start}"* ]]; then
			GITHUB_REPO_SSH="${url}"
			return 0
		fi
	fi

	GITHUB_REPO_SSH="${GITHUB_REPO_SSH:-ssh://git@github.com/<org>/<repo>.git}"
}

# ---------------------------------------------------------------------------
# GitRepository apply + Ready wait (with deploy-key auto-detection)
# ---------------------------------------------------------------------------
apply_gitrepository() {
	if ! kubectl apply --server-side -f "${PROJECT_ROOT}/deploy/flux/git-repository.yaml"; then
		log_error "Failed to apply deploy/flux/git-repository.yaml"
		return 1
	fi
	log_success "GitRepository ${PROJECT_NAME} applied (namespace ${FLUX_NAMESPACE})"
}

print_deploy_key() {
	local pub
	# base64 decode flag differs across platforms (GNU --decode/-d, BSD -D)
	pub="$(kubectl get secret "${DEPLOY_KEY_SECRET}" -n "${FLUX_NAMESPACE}" \
		-o jsonpath='{.data.identity\.pub}' 2>/dev/null | base64 --decode 2>/dev/null || base64 -d 2>/dev/null || base64 -D 2>/dev/null || true)"
	if [[ -z "${pub}" ]]; then
		log_warning "Could not read identity.pub from secret ${DEPLOY_KEY_SECRET}"
		return 0
	fi
	echo ""
	echo -e "${GREEN}════════════════ DEPLOY KEY (public) ════════════════${NC}"
	echo "${pub}"
	echo -e "${GREEN}═════════════════════════════════════════════════════${NC}"
}

print_github_instructions() {
	echo ""
	log_info "Add this key on GitHub:"
	log_info "  Repo → Settings → Deploy keys → 'Add deploy key'"
	log_info "  Title: ${PROJECT_NAME}-prod-flux (any name)"
	log_info "  Key:   paste the public key above"
	log_info "  ☐ Allow write access — REQUIRED only if Flux image updates are enabled (enable_image_updates)"
	echo ""
}

poll_gitrepository_after_key() {
	local i=1
	while ((i <= DEPLOY_KEY_POLL_ATTEMPTS)); do
		log_info "Waiting for GitRepository ${PROJECT_NAME} — attempt ${i}/${DEPLOY_KEY_POLL_ATTEMPTS} (up to 5m total)..."
		if kubectl wait --for=condition=Ready "gitrepository/${PROJECT_NAME}" -n "${FLUX_NAMESPACE}" \
			--timeout="${DEPLOY_KEY_POLL_WAIT}" >/dev/null 2>&1; then
			log_success "GitRepository ${PROJECT_NAME} is Ready"
			return 0
		fi
		i=$((i + 1))
	done

	log_error "GitRepository ${PROJECT_NAME} still not Ready after 5m."
	log_error "FIRST RUN FAILS BY DESIGN until the deploy key is added to GitHub:"
	echo ""
	print_deploy_key
	print_github_instructions
	echo ""
	echo "GitRepository conditions (for debugging):"
	kubectl get gitrepository "${PROJECT_NAME}" -n "${FLUX_NAMESPACE}" -o jsonpath='{.status.conditions}' 2>/dev/null || true
	echo ""
	log_info "After adding the key on GitHub, re-run: make prod-deploy"
	exit 1
}

# Create the deploy-key secret — NEVER rotate/recreate an existing one.
provision_deploy_key() {
	if kubectl get secret "${DEPLOY_KEY_SECRET}" -n "${FLUX_NAMESPACE}" >/dev/null 2>&1; then
		log_info "Secret ${DEPLOY_KEY_SECRET} already exists — NOT recreating it (never rotates an existing key)"
		print_deploy_key
		print_github_instructions
		return 0
	fi

	log_info "Creating SSH deploy key secret '${DEPLOY_KEY_SECRET}' via flux CLI..."
	if ! flux create secret git "${DEPLOY_KEY_SECRET}" -n "${FLUX_NAMESPACE}" --url "${GITHUB_REPO_SSH}"; then
		log_error "Failed to create deploy key secret"
		log_info "Ensure the flux CLI is installed: https://fluxcd.io/flux/installation/"
		log_info "Manual equivalent: flux create secret git ${DEPLOY_KEY_SECRET} -n ${FLUX_NAMESPACE} --url ${GITHUB_REPO_SSH}"
		exit 1
	fi
	log_success "Secret ${DEPLOY_KEY_SECRET} created"
	print_deploy_key
	print_github_instructions
}

handle_auth_failure() {
	log_warning "Authentication failure detected on GitRepository ${PROJECT_NAME}"
	echo ""

	provision_deploy_key

	poll_gitrepository_after_key
}

# Bounded initial wait: GITREPO_POLL_ATTEMPTS x GITREPO_POLL_WAIT. Conditions
# are inspected after every failed attempt — an auth failure never self-heals,
# so it jumps straight to the deploy-key flow instead of burning the budget.
ensure_gitrepository_ready() {
	local attempt=1 msg
	while ((attempt <= GITREPO_POLL_ATTEMPTS)); do
		log_info "Waiting for GitRepository ${PROJECT_NAME} to become Ready — attempt ${attempt}/${GITREPO_POLL_ATTEMPTS} (${GITREPO_POLL_WAIT} each)..."
		if kubectl wait --for=condition=Ready "gitrepository/${PROJECT_NAME}" -n "${FLUX_NAMESPACE}" \
			--timeout="${GITREPO_POLL_WAIT}" >/dev/null 2>&1; then
			log_success "GitRepository ${PROJECT_NAME} is Ready"
			return 0
		fi

		msg="$(kubectl get gitrepository "${PROJECT_NAME}" -n "${FLUX_NAMESPACE}" \
			-o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || true)"

		if [[ "${msg}" =~ (authentication|permission|publickey|credentials|unauthorized|forbidden) ]]; then
			handle_auth_failure
			return 0
		fi

		log_warning "GitRepository ${PROJECT_NAME} not Ready yet (message: ${msg:-none}) — retrying..."
		attempt=$((attempt + 1))
	done

	# Bounded wait exhausted with no Ready condition and no auth keyword.
	log_error "GitRepository ${PROJECT_NAME} not Ready after ${GITREPO_POLL_ATTEMPTS} attempts x ${GITREPO_POLL_WAIT}."
	echo ""
	echo "GitRepository conditions:"
	kubectl get gitrepository "${PROJECT_NAME}" -n "${FLUX_NAMESPACE}" -o jsonpath='{.status.conditions}' 2>/dev/null || true
	echo ""
	log_error "GitRepository failed for a NON-auth reason (message: ${msg:-unknown})"
	log_info "This is usually cluster→github.com network/DNS connectivity, or the branch not existing."
	log_info "Check: kubectl describe gitrepository ${PROJECT_NAME} -n ${FLUX_NAMESPACE}"
	exit 1
}

# ---------------------------------------------------------------------------
# Standalone entry point (not used when this file is sourced)
# ---------------------------------------------------------------------------
usage() {
	cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [--dry-run]

Provisions the Flux GitRepository + deploy key (idempotent; never rotates an
existing ${DEPLOY_KEY_SECRET} secret):
  1. kubectl apply --server-side -f deploy/flux/git-repository.yaml
  2. Wait for GitRepository Ready (bounded re-poll; auth failures jump
     straight to the deploy-key flow)
  3. On auth failure: create the deploy-key secret via the flux CLI (first
     run only), print the public key + GitHub instructions, poll up to ~5m

Options:
  --dry-run     Print the planned actions. No cluster access, nothing executed.
  -h, --help    Show this help

Environment overrides: KUBECONFIG (ambient), PROJECT_NAME, GITHUB_REPO_SSH,
DEPLOY_KEY_SECRET, FLUX_NAMESPACE.
EOF
}

dry_run_flow() {
	echo ""
	log_info "Dry-run mode — printing planned actions (nothing will execute, no cluster access)"
	echo ""
	echo "  [dry-run] PROJECT_NAME:      ${PROJECT_NAME}"
	echo "  [dry-run] GITHUB_REPO_SSH:   ${GITHUB_REPO_SSH}"
	echo "  [dry-run] GitRepository:     ${PROJECT_NAME} in ${FLUX_NAMESPACE}"
	echo "  [dry-run] deploy-key secret: ${DEPLOY_KEY_SECRET} (never rotated once it exists)"
	echo ""
	echo "  [dry-run] kubectl apply --server-side -f deploy/flux/git-repository.yaml"
	echo "  [dry-run] wait for GitRepository Ready: ${GITREPO_POLL_ATTEMPTS} attempts x ${GITREPO_POLL_WAIT} each (conditions inspected between attempts)"
	echo "  [dry-run] on auth failure: if secret ${DEPLOY_KEY_SECRET} exists → print existing identity.pub (never recreate)"
	echo "  [dry-run]   else: flux create secret git ${DEPLOY_KEY_SECRET} -n ${FLUX_NAMESPACE} --url ${GITHUB_REPO_SSH}"
	echo "  [dry-run]   → print identity.pub + GitHub deploy-key instructions → poll GitRepository Ready up to 5m"
	echo ""
	log_success "Dry-run complete — zero cluster calls made"
}

main() {
	local dry_run=false
	for arg in "$@"; do
		case "${arg}" in
		--dry-run)
			dry_run=true
			;;
		-h | --help)
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

	resolve_project_name
	resolve_github_repo_ssh

	if [[ "${dry_run}" == "true" ]]; then
		echo ""
		echo "==================================================================="
		echo "Deploy-key provisioning (DRY RUN): ${PROJECT_NAME}"
		echo "==================================================================="
		dry_run_flow
		exit 0
	fi

	echo ""
	echo "==================================================================="
	echo "Deploy-key provisioning: ${PROJECT_NAME}"
	echo "==================================================================="
	echo ""

	if ! apply_gitrepository; then
		exit 1
	fi
	echo ""
	ensure_gitrepository_ready
}

# Run standalone (skipped when sourced by deploy.sh)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
