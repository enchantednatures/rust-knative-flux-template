#!/bin/bash
#
# Production Deploy Script (GitOps via FluxCD)
#
# Deploys this service to the production Kubernetes cluster through FluxCD:
#   GitRepository source → deploy-key auto-detection → prod Flux config →
#   reconciliation waits → Knative service readiness → in-cluster health
#   smoke suite (detached curl pods).
#
# This script NEVER:
#   - builds/pushes images (Flux image automation owns tags)
#   - applies workloads directly (only Flux config objects; Flux applies the rest)
#   - auto-installs the Flagger operator (fail-fast pre-flight only)
#   - rotates an existing github-deploy-key secret
#
# Usage:
#   make prod-deploy                    (Makefile passes GITHUB_ORG/GITHUB_REPO/GITHUB_REPO_SSH)
#   ./scripts/prod/deploy.sh            (standalone; names auto-resolved from Makefile)
#   ./scripts/prod/deploy.sh --dry-run  (print the full plan, touch nothing)
#
# Environment:
#   KUBECONFIG         kubeconfig to use (else ${PROJECT_ROOT}/.kubeconfig-prod)
#   PROJECT_NAME       override service name (default: parsed from Makefile)
#   GITHUB_ORG         GitHub org (Makefile passes; baked at generation time)
#   GITHUB_REPO        GitHub repo (Makefile passes)
#   GITHUB_REPO_SSH    SSH URL (Makefile passes; fallback: parsed from git-repository.yaml)
#   SERVICE_URL        override the Knative service URL used by the smoke suite
#
# Exit codes:
#   0 success · 1 any deployment/smoke failure (with diagnostics)
#

set -euo pipefail

# Project root (two levels up from this script: scripts/prod/ -> repo root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Configuration
PROD_KUBECONFIG_PATH=".kubeconfig-prod"
PROD_NAMESPACE="production"
FLUX_NAMESPACE="flux-system"
DEPLOY_KEY_SECRET="github-deploy-key"
SMOKE_IMAGE="curlimages/curl:8.10.1"
GITREPO_INITIAL_WAIT="90s"      # first GitRepository Ready wait
DEPLOY_KEY_POLL_ATTEMPTS=20     # 20 x 15s kubectl wait = 5m max
DEPLOY_KEY_POLL_WAIT="15s"
RECONCILE_WAIT="5m"             # Kustomization + HelmRelease readiness
KSVS_WAIT="5m"                  # Knative service readiness
SMOKE_TIMEOUT=90                # per-check pod poll (seconds, covers image pull + cold start)

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

# [N/9] step banner
step() {
	local n="$1"
	local title="$2"
	echo ""
	echo -e "${YELLOW}[${n}/9]${NC} ${title}"
}

usage() {
	cat <<EOF
Usage: $(basename "$0") [--dry-run]

Deploys to production via FluxCD and runs an in-cluster health smoke suite.

Options:
  --dry-run     Print every planned action (all 9 steps + 4 smoke checks)
                with resolved names/URLs. No cluster access, nothing executed.
  -h, --help    Show this help

Environment overrides: KUBECONFIG, PROJECT_NAME, GITHUB_ORG, GITHUB_REPO,
GITHUB_REPO_SSH, SERVICE_URL (see script header for details).
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

# ---------------------------------------------------------------------------
# Name / URL resolution (pure file work — no cluster access, dry-run safe)
# ---------------------------------------------------------------------------
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
	fi
}

# GITHUB_REPO_SSH: env (from Makefile) → org/repo → git-repository.yaml → placeholder.
resolve_github_repo_ssh() {
	if [[ -n "${GITHUB_REPO_SSH:-}" ]]; then
		return 0
	fi

	if [[ -n "${GITHUB_ORG:-}" && -n "${GITHUB_REPO:-}" ]]; then
		GITHUB_REPO_SSH="ssh://git@github.com/${GITHUB_ORG}/${GITHUB_REPO}.git"
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
# Smoke-suite state (detached-pod pattern; pods always cleaned up on exit)
# ---------------------------------------------------------------------------
declare -a SMOKE_PODS=()
SMOKE_EXIT_CODE=1
SMOKE_OUTPUT=""
SMOKE_POD_PHASE=""
SMOKE_HTTP_CODE=""
SMOKE_BODY=""
CURRENT_CHECK=""
PASSED=0
FAILED=0

cleanup() {
	local pod
	if ((${#SMOKE_PODS[@]} > 0)); then
		for pod in "${SMOKE_PODS[@]}"; do
			kubectl delete pod "${pod}" -n "${PROD_NAMESPACE}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
		done
	fi
}
trap cleanup EXIT

# Run curl inside a DETACHED pod (no attach, no --rm — avoids the k8s attach
# race kubernetes#27264). Polls .status.phase for a terminal state, reads the
# curl exit code from containerStatuses[0].state.terminated.exitCode, captures
# logs, deletes the pod.
#
# Sets globals: SMOKE_EXIT_CODE (curl rc; 124=pod stuck; 125=create failed),
# SMOKE_OUTPUT (pod logs: body + trailing http_code line), SMOKE_POD_PHASE.
# Always returns 0 — outcome is communicated via SMOKE_EXIT_CODE (set -e safe).
pod_curl() {
	local url="$1"
	SMOKE_EXIT_CODE=1
	SMOKE_OUTPUT=""
	SMOKE_POD_PHASE=""
	SMOKE_HTTP_CODE=""
	SMOKE_BODY=""

	local pod="prod-smoke-${CURRENT_CHECK}-${RANDOM}"
	SMOKE_PODS+=("${pod}")

	log_info "  probe pod: kubectl run ${pod} -n ${PROD_NAMESPACE} (image ${SMOKE_IMAGE})"
	if ! kubectl run "${pod}" -n "${PROD_NAMESPACE}" --restart=Never \
		--image="${SMOKE_IMAGE}" --quiet -- \
		curl -f -s --max-time 60 -w '\n%{http_code}' "${url}" >/dev/null 2>&1; then
		log_error "  failed to create probe pod ${pod}"
		kubectl delete pod "${pod}" -n "${PROD_NAMESPACE}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
		SMOKE_EXIT_CODE=125
		return 0
	fi

	local phase="" i=1
	while ((i <= SMOKE_TIMEOUT)); do
		phase="$(kubectl get pod "${pod}" -n "${PROD_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
		case "${phase}" in
		Succeeded | Failed) break ;;
		esac
		if ((i == 1 || i % 10 == 0)); then
			log_info "  waiting for probe pod ${pod} — attempt ${i}/${SMOKE_TIMEOUT} (phase=${phase:-Pending})"
		fi
		sleep 1
		i=$((i + 1))
	done
	SMOKE_POD_PHASE="${phase}"

	if [[ "${phase}" != "Succeeded" && "${phase}" != "Failed" ]]; then
		log_warning "  probe pod ${pod} did not reach a terminal phase within ${SMOKE_TIMEOUT}s (last phase=${phase:-unknown})"
		kubectl delete pod "${pod}" -n "${PROD_NAMESPACE}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
		SMOKE_EXIT_CODE=124 # stuck — caller may retry against the in-cluster URL
		return 0
	fi

	# Exit code from the terminated container state (fail-closed default 1)
	SMOKE_EXIT_CODE="$(kubectl get pod "${pod}" -n "${PROD_NAMESPACE}" \
		-o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || true)"
	[[ -n "${SMOKE_EXIT_CODE}" ]] || SMOKE_EXIT_CODE=1

	# Durable, complete output (valid for terminated containers)
	SMOKE_OUTPUT="$(kubectl logs "${pod}" -n "${PROD_NAMESPACE}" 2>/dev/null || true)"
	kubectl delete pod "${pod}" -n "${PROD_NAMESPACE}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
	return 0
}

# Split SMOKE_OUTPUT into SMOKE_HTTP_CODE (last line) + SMOKE_BODY (the rest).
smoke_parse() {
	SMOKE_HTTP_CODE=""
	SMOKE_BODY=""
	if [[ -z "${SMOKE_OUTPUT}" ]]; then
		return 0
	fi
	SMOKE_HTTP_CODE="$(printf '%s\n' "${SMOKE_OUTPUT}" | tail -n 1 | tr -d '[:space:]')"
	SMOKE_BODY="$(printf '%s' "${SMOKE_OUTPUT}" | sed '$d')"
	return 0
}

# One smoke assertion: 200 + body contains <expect_body>.
# curl exit 6 (DNS) / 7 (connect) / 28 (timeout) or a stuck pod triggers one
# retry against the in-cluster service URL.
run_smoke_check() {
	local check_name="$1"
	local path="$2"
	local description="$3"
	local expect_body="$4"

	CURRENT_CHECK="${check_name}"
	local url="${SERVICE_URL}${path}"

	echo ""
	log_info "Test: ${description} — GET ${url}"

	pod_curl "${url}"
	local rc="${SMOKE_EXIT_CODE}"

	if [[ "${rc}" == "6" || "${rc}" == "7" || "${rc}" == "28" || "${rc}" == "124" ]]; then
		local fallback_url="http://${PROJECT_NAME}.${PROD_NAMESPACE}.svc.cluster.local${path}"
		log_warning "  probe failed (curl exit ${rc}) — retrying against in-cluster URL: ${fallback_url}"
		pod_curl "${fallback_url}"
		rc="${SMOKE_EXIT_CODE}"
	fi

	local http_code="" body=""
	if [[ "${rc}" == "0" || "${rc}" == "22" ]]; then
		smoke_parse
		http_code="${SMOKE_HTTP_CODE}"
		body="${SMOKE_BODY}"
	fi

	local ok=true
	if [[ "${http_code}" != "200" ]]; then
		ok=false
	fi
	if [[ "${body}" != *"${expect_body}"* ]]; then
		ok=false
	fi

	if [[ "${ok}" == "true" ]]; then
		echo -e "  ${GREEN}✓ ${description} PASSED${NC} (HTTP ${http_code})"
		PASSED=$((PASSED + 1))
	else
		echo -e "  ${RED}✗ ${description} FAILED${NC} (curl exit=${rc}, HTTP=${http_code:-n/a}, expected body substring: ${expect_body})"
		if [[ -n "${body}" ]]; then
			echo "  --- probe output (first 15 lines) ---"
			printf '%s\n' "${body}" | head -15 | sed 's/^/  | /'
		fi
		FAILED=$((FAILED + 1))
	fi
}

# ---------------------------------------------------------------------------
# Pre-flight: Flagger dependency (fail fast; NEVER auto-install)
# ---------------------------------------------------------------------------
check_flagger_dependency() {
	local kf="${PROJECT_ROOT}/deploy/flux/kustomization-prod.yaml"
	if [[ ! -f "${kf}" ]]; then
		return 0
	fi
	if ! grep -q 'dependsOn:' "${kf}"; then
		return 0
	fi
	if ! grep -A2 'dependsOn:' "${kf}" | grep -q 'name: flagger'; then
		return 0
	fi

	log_info "Kustomization depends on 'flagger' — verifying the flagger Kustomization exists..."
	local out rc
	out="$(kubectl get kustomization flagger -n "${FLUX_NAMESPACE}" 2>&1)" && rc=0 || rc=$?
	if [[ ${rc} -eq 0 ]]; then
		log_success "Flagger dependency satisfied (kustomization/flagger found)"
		return 0
	fi
	if [[ "${out}" == *Forbidden* || "${out}" == *"403"* ]]; then
		# RBAC-restricted identity cannot verify cluster-owned prerequisites.
		log_warning "Cannot verify kustomization/flagger (RBAC-restricted identity) — continuing"
		return 0
	fi

	log_error "deploy/flux/kustomization-prod.yaml declares dependsOn: flagger, but"
	log_error "Kustomization 'flagger' was not found in namespace ${FLUX_NAMESPACE}"
	log_info "Install the Flagger operator CLUSTER-WIDE first (see docs/FLAGGER.md):"
	log_info "  flux create kustomization flagger ...  or your cluster management tooling"
	log_info "This script never auto-installs cluster-wide operators."
	exit 1
}

# ---------------------------------------------------------------------------
# Step 4 helper: deploy-key auto-detection
# ---------------------------------------------------------------------------
print_deploy_key() {
	local pub
	pub="$(kubectl get secret "${DEPLOY_KEY_SECRET}" -n "${FLUX_NAMESPACE}" \
		-o jsonpath='{.data.identity\.pub}' 2>/dev/null | base64 --decode 2>/dev/null || true)"
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

handle_auth_failure() {
	log_warning "Authentication failure detected on GitRepository ${PROJECT_NAME}"
	echo ""

	# Secret-existence guard FIRST — never rotate/recreate an existing key.
	if kubectl get secret "${DEPLOY_KEY_SECRET}" -n "${FLUX_NAMESPACE}" >/dev/null 2>&1; then
		log_info "Secret ${DEPLOY_KEY_SECRET} already exists — NOT recreating it (never rotates an existing key)"
		print_deploy_key
		print_github_instructions
	else
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
	fi

	poll_gitrepository_after_key
}

ensure_gitrepository_ready() {
	log_info "Waiting for GitRepository ${PROJECT_NAME} to become Ready (timeout ${GITREPO_INITIAL_WAIT})..."
	if kubectl wait --for=condition=Ready "gitrepository/${PROJECT_NAME}" -n "${FLUX_NAMESPACE}" \
		--timeout="${GITREPO_INITIAL_WAIT}" >/dev/null 2>&1; then
		log_success "GitRepository ${PROJECT_NAME} is Ready"
		return 0
	fi

	log_warning "GitRepository ${PROJECT_NAME} not Ready within ${GITREPO_INITIAL_WAIT} — inspecting conditions..."
	echo ""
	echo "GitRepository conditions:"
	kubectl get gitrepository "${PROJECT_NAME}" -n "${FLUX_NAMESPACE}" -o jsonpath='{.status.conditions}' 2>/dev/null || true
	echo ""

	local msg
	msg="$(kubectl get gitrepository "${PROJECT_NAME}" -n "${FLUX_NAMESPACE}" \
		-o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || true)"

	if [[ "${msg}" =~ (authentication|permission|publickey|credentials|unauthorized|forbidden) ]]; then
		handle_auth_failure
		return 0
	fi

	# Network/DNS or any other non-auth failure — diagnostics + exit.
	log_error "GitRepository failed for a NON-auth reason (message: ${msg:-unknown})"
	log_info "This is usually cluster→github.com network/DNS connectivity, or the branch not existing."
	log_info "Check: kubectl describe gitrepository ${PROJECT_NAME} -n ${FLUX_NAMESPACE}"
	exit 1
}

# ---------------------------------------------------------------------------
# Dry-run: print every planned action; zero cluster access
# ---------------------------------------------------------------------------
dry_run_flow() {
	local kubeconfig_plan
	if [[ -n "${KUBECONFIG:-}" ]]; then
		kubeconfig_plan="KUBECONFIG env: ${KUBECONFIG}"
	elif [[ -f "${PROJECT_ROOT}/${PROD_KUBECONFIG_PATH}" ]]; then
		kubeconfig_plan="${PROJECT_ROOT}/${PROD_KUBECONFIG_PATH}"
	else
		kubeconfig_plan="NOT FOUND — real run would exit 1 (set KUBECONFIG or create ${PROD_KUBECONFIG_PATH}; see: make prod-kubeconfig)"
	fi

	local service_url_plan="${SERVICE_URL:-}"
	if [[ -n "${SERVICE_URL:-}" ]]; then
		service_url_plan="${SERVICE_URL} (SERVICE_URL env override)"
	else
		service_url_plan="resolved at runtime via: kubectl get ksvc ${PROJECT_NAME} -n ${PROD_NAMESPACE} -o jsonpath='{.status.url}'"
	fi

	echo ""
	log_info "Dry-run mode — printing planned actions (nothing will execute, no cluster access)"
	echo ""

	step "1" "Kubeconfig resolution"
	echo "  [dry-run] ${kubeconfig_plan}"

	step "2" "Pre-flight checks"
	echo "  [dry-run] kubectl cluster-info                      # cluster reachable (fallback: /readyz probe)"
	echo "  [dry-run] kubectl get namespace flux-system         # Flux installed"
	echo "  [dry-run] kubectl -n flux-system get deployment source-controller  # source-controller Available"
	echo "  [dry-run] kubectl get namespace knative-serving     # Knative installed"
	echo "  [dry-run] grep dependsOn deploy/flux/kustomization-prod.yaml → if 'flagger': kubectl get kustomization flagger -n flux-system (fail fast, never auto-install)"

	step "3" "Apply GitRepository"
	echo "  [dry-run] kubectl apply --server-side -f deploy/flux/git-repository.yaml   (GitRepository ${PROJECT_NAME} in ${FLUX_NAMESPACE})"

	step "4" "Deploy key auto-detection"
	echo "  [dry-run] kubectl wait --for=condition=Ready gitrepository/${PROJECT_NAME} -n ${FLUX_NAMESPACE} --timeout=${GITREPO_INITIAL_WAIT}"
	echo "  [dry-run] on auth failure: if secret ${DEPLOY_KEY_SECRET} exists → print existing identity.pub (never recreate)"
	echo "  [dry-run]   else: flux create secret git ${DEPLOY_KEY_SECRET} -n ${FLUX_NAMESPACE} --url ${GITHUB_REPO_SSH}"
	echo "  [dry-run]   → print identity.pub + GitHub deploy-key instructions → poll GitRepository Ready up to 5m"

	step "5" "Apply prod Flux config"
	echo "  [dry-run] kubectl kustomize --load-restrictor LoadRestrictionsNone deploy/flux/config/prod | kubectl apply --server-side -f -"
	echo "  [dry-run]   (config/prod references ../../kustomization-prod.yaml outside the build root — 'kubectl apply -k' would fail load restrictions)"

	step "6" "Wait for Flux reconciliation"
	echo "  [dry-run] kubectl wait --for=condition=Ready kustomization/${PROJECT_NAME}-prod -n ${FLUX_NAMESPACE} --timeout=${RECONCILE_WAIT}"
	echo "  [dry-run] kubectl wait --for=condition=Ready helmrelease/${PROJECT_NAME} -n ${PROD_NAMESPACE} --timeout=${RECONCILE_WAIT}"

	step "7" "Wait for Knative service"
	echo "  [dry-run] kubectl wait --for=condition=Ready ksvc/${PROJECT_NAME} -n ${PROD_NAMESPACE} --timeout=${KSVS_WAIT}"
	echo "  [dry-run] on failure: dump ksvc yaml + pod list + last 50 logs + events"

	step "8" "Smoke suite (detached curl pods, image ${SMOKE_IMAGE})"
	echo "  [dry-run] SERVICE_URL: ${service_url_plan}"
	echo "  [dry-run] fallback URL: http://${PROJECT_NAME}.${PROD_NAMESPACE}.svc.cluster.local (on curl exit 6/7/28 or stuck pod)"
	echo "  [dry-run] kubectl run prod-smoke-health-live-\$RANDOM -n ${PROD_NAMESPACE} --restart=Never --image=${SMOKE_IMAGE} -- curl -f -s --max-time 60 <url>/health/live"
	echo "  [dry-run] kubectl run prod-smoke-health-ready-\$RANDOM -n ${PROD_NAMESPACE} --restart=Never --image=${SMOKE_IMAGE} -- curl -f -s --max-time 60 <url>/health/ready"
	echo "  [dry-run] kubectl run prod-smoke-metrics-\$RANDOM -n ${PROD_NAMESPACE} --restart=Never --image=${SMOKE_IMAGE} -- curl -f -s --max-time 60 <url>/metrics"
	echo "  [dry-run] kubectl run prod-smoke-hello-\$RANDOM -n ${PROD_NAMESPACE} --restart=Never --image=${SMOKE_IMAGE} -- curl -f -s --max-time 60 <url>/api/v1/hello"

	step "9" "Summary"
	echo "  [dry-run] assert: /health/live → 200 + body contains {\"status\":\"alive\"}"
	echo "  [dry-run] assert: /health/ready → 200 + body contains {\"status\":\"ready\"}"
	echo "  [dry-run] assert: /metrics → 200 + body contains # HELP"
	echo "  [dry-run] assert: /api/v1/hello → 200 + body contains message"
	echo "  [dry-run] exit non-zero if any check failed"

	echo ""
	log_success "Dry-run complete — 9 steps + 4 smoke checks planned; zero cluster calls made"
}

# ---------------------------------------------------------------------------
# Main execution (real run)
# ---------------------------------------------------------------------------
main() {
	echo ""
	echo "==================================================================="
	echo "Production Deploy: ${PROJECT_NAME}"
	echo "==================================================================="

	# [1/9] Kubeconfig resolution
	step "1" "Resolving kubeconfig"
	if [[ -n "${KUBECONFIG:-}" ]]; then
		log_info "Using KUBECONFIG from environment: ${KUBECONFIG}"
	elif [[ -f "${PROJECT_ROOT}/${PROD_KUBECONFIG_PATH}" ]]; then
		export KUBECONFIG="${PROJECT_ROOT}/${PROD_KUBECONFIG_PATH}"
		log_info "Using ${KUBECONFIG}"
	else
		log_error "No production kubeconfig available"
		echo ""
		echo "  Provide one of:"
		echo "    1. export KUBECONFIG=/path/to/prod-kubeconfig"
		echo "    2. Place the kubeconfig at ${PROJECT_ROOT}/${PROD_KUBECONFIG_PATH}"
		echo "       (show the path hint with: make prod-kubeconfig)"
		echo ""
		exit 1
	fi

	if ! command -v kubectl >/dev/null 2>&1; then
		log_error "kubectl is required but not installed"
		exit 1
	fi

	# [2/9] Pre-flights
	step "2" "Running pre-flight checks"

	# a) Cluster reachable. cluster-info may fail under restricted RBAC —
	#    fall back to the /readyz probe (granted to every authenticated user).
	if kubectl cluster-info >/dev/null 2>&1; then
		log_success "Kubernetes cluster reachable"
	elif kubectl get --raw=/readyz >/dev/null 2>&1; then
		log_warning "kubectl cluster-info unavailable (restricted identity) but API server responds on /readyz — continuing"
	else
		log_error "Cannot reach the Kubernetes cluster"
		log_info "Check KUBECONFIG (${KUBECONFIG:-unset}) and network/VPN connectivity"
		exit 1
	fi

	# b) Flux installed: flux-system namespace + source-controller Available.
	local flux_out flux_rc
	flux_out="$(kubectl get namespace flux-system 2>&1)" && flux_rc=0 || flux_rc=$?
	if [[ ${flux_rc} -ne 0 ]]; then
		if [[ "${flux_out}" == *Forbidden* || "${flux_out}" == *"403"* ]]; then
			log_warning "Cannot verify flux-system namespace (RBAC-restricted identity) — continuing; the GitRepository apply fails loudly if Flux is missing"
		else
			log_error "Flux is not installed: namespace 'flux-system' not found"
			log_info "Install Flux first: https://fluxcd.io/flux/installation/"
			exit 1
		fi
	else
		log_success "Flux namespace '${FLUX_NAMESPACE}' present"
		local sc_out sc_rc
		sc_out="$(kubectl -n "${FLUX_NAMESPACE}" get deployment source-controller \
			-o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>&1)" && sc_rc=0 || sc_rc=$?
		if [[ ${sc_rc} -ne 0 ]]; then
			if [[ "${sc_out}" == *Forbidden* || "${sc_out}" == *"403"* ]]; then
				log_warning "Cannot verify source-controller deployment (RBAC-restricted identity) — continuing"
			else
				log_error "Flux source-controller deployment not found in ${FLUX_NAMESPACE}"
				log_info "Flux installation appears incomplete — re-run flux bootstrap"
				exit 1
			fi
		elif [[ "${sc_out}" == "True" ]]; then
			log_success "Flux source-controller is Available"
		else
			log_error "Flux source-controller is not Available (status=${sc_out:-unknown})"
			exit 1
		fi
	fi

	# c) Knative installed.
	local kn_out kn_rc
	kn_out="$(kubectl get namespace knative-serving 2>&1)" && kn_rc=0 || kn_rc=$?
	if [[ ${kn_rc} -ne 0 ]]; then
		if [[ "${kn_out}" == *Forbidden* || "${kn_out}" == *"403"* ]]; then
			log_warning "Cannot verify knative-serving namespace (RBAC-restricted identity) — continuing"
		else
			log_error "Knative Serving is not installed: namespace 'knative-serving' not found"
			log_info "Knative Serving must be installed cluster-wide before deploying"
			exit 1
		fi
	else
		log_success "Knative namespace 'knative-serving' present"
	fi

	# d) Flagger dependency (only when the prod Kustomization declares it).
	check_flagger_dependency

	# [3/9] Apply GitRepository
	step "3" "Applying GitRepository"
	if ! kubectl apply --server-side -f "${PROJECT_ROOT}/deploy/flux/git-repository.yaml"; then
		log_error "Failed to apply deploy/flux/git-repository.yaml"
		exit 1
	fi
	log_success "GitRepository ${PROJECT_NAME} applied (namespace ${FLUX_NAMESPACE})"

	# [4/9] Deploy key auto-detection
	step "4" "Deploy key auto-detection"
	ensure_gitrepository_ready

	# [5/9] Apply prod Flux config
	step "5" "Applying prod Flux config"
	# NOTE: 'kubectl apply -k' uses LoadRestrictionsRootOnly and FAILS on the
	# ../../kustomization-prod.yaml outside-root reference — render explicitly
	# with LoadRestrictionsNone, then server-side apply. The rendered output
	# contains ONLY Flux config objects (Kustomizations/image CRs); Flux itself
	# applies all workloads.
	if ! kubectl kustomize --load-restrictor LoadRestrictionsNone "${PROJECT_ROOT}/deploy/flux/config/prod" |
		kubectl apply --server-side -f -; then
		log_error "Failed to apply prod Flux config (deploy/flux/config/prod)"
		exit 1
	fi
	log_success "Prod Flux config applied (Kustomization ${PROJECT_NAME}-prod)"

	# [6/9] Wait for Flux reconciliation
	step "6" "Waiting for Flux reconciliation"
	log_info "Waiting for Kustomization ${PROJECT_NAME}-prod (timeout ${RECONCILE_WAIT})..."
	if ! kubectl wait --for=condition=Ready "kustomization/${PROJECT_NAME}-prod" -n "${FLUX_NAMESPACE}" --timeout="${RECONCILE_WAIT}"; then
		log_error "Kustomization ${PROJECT_NAME}-prod failed to become Ready within ${RECONCILE_WAIT}"
		echo ""
		echo "Kustomization conditions:"
		kubectl get kustomization "${PROJECT_NAME}-prod" -n "${FLUX_NAMESPACE}" -o jsonpath='{.status.conditions}' 2>/dev/null || true
		echo ""
		if command -v flux >/dev/null 2>&1; then
			echo ""
			echo "flux get kustomizations:"
			flux get kustomizations --namespace "${FLUX_NAMESPACE}" 2>/dev/null || true
		fi
		exit 1
	fi
	log_success "Kustomization ${PROJECT_NAME}-prod is Ready"

	log_info "Waiting for HelmRelease ${PROJECT_NAME} (namespace ${PROD_NAMESPACE}, timeout ${RECONCILE_WAIT})..."
	if ! kubectl wait --for=condition=Ready "helmrelease/${PROJECT_NAME}" -n "${PROD_NAMESPACE}" --timeout="${RECONCILE_WAIT}" 2>/dev/null; then
		# The runner RBAC scopes helmreleases to flux-system only; a Forbidden
		# here is an identity limitation, not a deploy failure — the ksvc wait
		# below is the authoritative readiness gate.
		local hr_probe
		hr_probe="$(kubectl get helmrelease "${PROJECT_NAME}" -n "${PROD_NAMESPACE}" 2>&1 || true)"
		if [[ "${hr_probe}" == *Forbidden* || "${hr_probe}" == *"403"* || "${hr_probe}" == *"cannot get"* ]]; then
			log_warning "Cannot read helmrelease/${PROJECT_NAME} in ${PROD_NAMESPACE} (RBAC-restricted identity) — skipping to the Knative service wait"
		else
			log_error "HelmRelease ${PROJECT_NAME} failed to become Ready within ${RECONCILE_WAIT}"
			echo ""
			echo "HelmRelease conditions:"
			kubectl get helmrelease "${PROJECT_NAME}" -n "${PROD_NAMESPACE}" -o jsonpath='{.status.conditions}' 2>/dev/null || true
			echo ""
			echo "HelmRelease yaml:"
			kubectl get helmrelease "${PROJECT_NAME}" -n "${PROD_NAMESPACE}" -o yaml 2>/dev/null || true
			exit 1
		fi
	else
		log_success "HelmRelease ${PROJECT_NAME} is Ready"
	fi

	# [7/9] Wait for Knative service (canonical diagnostic dump on failure)
	step "7" "Waiting for Knative service"
	log_info "Waiting for ksvc/${PROJECT_NAME} (namespace ${PROD_NAMESPACE}, timeout ${KSVS_WAIT})..."
	if ! kubectl wait --for=condition=Ready "ksvc/${PROJECT_NAME}" -n "${PROD_NAMESPACE}" --timeout="${KSVS_WAIT}"; then
		log_error "Knative service ${PROJECT_NAME} failed to become Ready"
		echo ""
		echo "Service status:"
		kubectl get ksvc "${PROJECT_NAME}" -n "${PROD_NAMESPACE}" -o yaml 2>/dev/null || true
		echo ""
		echo "Pod status:"
		kubectl get pods -n "${PROD_NAMESPACE}" 2>/dev/null || true
		echo ""
		echo "Recent logs (last 50):"
		kubectl logs -l "serving.knative.dev/service=${PROJECT_NAME}" -c user-container -n "${PROD_NAMESPACE}" --tail=50 2>/dev/null || echo "No logs available"
		echo ""
		echo "Recent events:"
		kubectl get events -n "${PROD_NAMESPACE}" --sort-by=.lastTimestamp 2>/dev/null | tail -20 || true
		exit 1
	fi
	log_success "Knative service ${PROJECT_NAME} is Ready"

	# [8/9] Smoke suite
	step "8" "Running in-cluster health smoke suite"
	if [[ -n "${SERVICE_URL:-}" ]]; then
		log_info "Using SERVICE_URL override: ${SERVICE_URL}"
	else
		SERVICE_URL="$(kubectl get ksvc "${PROJECT_NAME}" -n "${PROD_NAMESPACE}" -o jsonpath='{.status.url}' 2>/dev/null || true)"
		if [[ -z "${SERVICE_URL}" ]]; then
			log_warning "ksvc status.url is empty — defaulting to the in-cluster service URL"
			SERVICE_URL="http://${PROJECT_NAME}.${PROD_NAMESPACE}.svc.cluster.local"
		fi
	fi
	log_info "Service URL: ${SERVICE_URL}"

	run_smoke_check "health-live" "/health/live" "Liveness probe" '{"status":"alive"}'
	run_smoke_check "health-ready" "/health/ready" "Readiness probe" '{"status":"ready"}'
	run_smoke_check "metrics" "/metrics" "Prometheus metrics" '# HELP'
	run_smoke_check "hello" "/api/v1/hello" "Hello API" 'message'

	# [9/9] Summary
	step "9" "Summary"
	echo ""
	echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
	echo -e "${BLUE}║           Production Deployment Summary                ║${NC}"
	echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
	echo ""
	echo -e "  Service:      ${GREEN}${PROJECT_NAME}${NC} (namespace ${PROD_NAMESPACE})"
	echo -e "  Service URL:  ${GREEN}${SERVICE_URL}${NC}"
	echo -e "  Smoke checks: ${GREEN}${PASSED} passed${NC} / ${RED}${FAILED} failed${NC}"
	echo ""

	if ((FAILED > 0)); then
		log_error "${FAILED} smoke check(s) failed — deployment NOT verified"
		exit 1
	fi

	log_success "Production deployment verified — ${PASSED}/${PASSED} smoke checks passed"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
resolve_project_name
resolve_github_repo_ssh

if [[ "${DRY_RUN}" == "true" ]]; then
	echo ""
	echo "==================================================================="
	echo "Production Deploy (DRY RUN): ${PROJECT_NAME}"
	echo "==================================================================="
	dry_run_flow
	exit 0
fi

if [[ ! -t 0 ]]; then :; fi # no interactive prompts anywhere (CI-safe)

main "$@"
