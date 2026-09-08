#!/bin/bash
#
# test-prod-deploy-static.sh — Static validation harness for prod deploy tooling
#
# TDD foundation for the prod-deploy plan: generates this cargo-generate
# template into temp dirs across a feature-flag matrix and asserts on the
# generated output (pure static validation — NO Kubernetes cluster needed).
#
# Asserted artifacts (owned by later tasks; this harness is RED until they land):
#   scripts/prod/deploy.sh                 (Task 3)
#   scripts/prod/create-github-env.sh      (Task 5)
#   Makefile prod-* targets + vars         (Tasks 3, 5)
#   deploy/flux/git-repository.yaml SSH + secretRef  (Task 2)
#   deploy/overlays/prod namespace.yaml    (Task 2)
#   deploy/infrastructure/gha-runner RBAC  (Task 4)
#   .github/workflows/deploy.yaml.liquid   (Task 6)
#
# Usage:
#   ./scripts/test-prod-deploy-static.sh                    # full matrix (8 combos)
#   PROD_DEPLOY_MATRIX="0,0,0" ./scripts/test-prod-deploy-static.sh   # single combo
#     (comma-separated flags: feature_gha_runner,enable_image_updates,feature_flagger)
#
# Environment:
#   PROD_DEPLOY_MATRIX   "G,I,F" (0/1 each) to run a single combo for fast iteration
#   KEEP_OUTPUT=1        Preserve generated projects after the run
#
# Prerequisites:
#   cargo-generate (required), kustomize OR kubectl (required), python3+PyYAML
#   (optional — workflow YAML parse degrades to grep sanity check without it)
#
# Notes:
#   - cargo generate runs WITHOUT --allow-commands: the post-generate hook is
#     invoked but its system commands (clippy --fix / cargo fmt) are blocked,
#     which keeps the harness fast. Static validation does not need them.
#   - The template is copied to a temp dir without .git/ first: cargo-generate
#     reads from the git index when --path points inside a git repo, which
#     would hide uncommitted work-in-progress artifacts (same approach as
#     scripts/test-template-matrix.sh).
#   - kustomize builds use --load-restrictor LoadRestrictionsNone because
#     deploy/flux/config/prod references ../../kustomization-prod.yaml, which
#     lives outside the build root (same approach as test-template-e2e-local.sh).
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
APP_NAME="prod-matrix-app"
MATRIX="${PROD_DEPLOY_MATRIX:-}"

# Globals
WORK_DIR=""
TEMPLATE_COPY=""
KUSTOMIZE_BUILD=()          # ("kustomize" "build") or ("kubectl" "kustomize")
KUST_FLAGS=(--load-restrictor LoadRestrictionsNone)
HAVE_PY3_YAML=0

TOTAL_COMBOS=0
PASSED_COMBOS=0
FAILED_COMBOS=0
FAILED_LIST=()

# Per-combo state
COMBO_LABEL=""
COMBO_FAILURES=0
GEN_DIR=""

# ── Logging helpers ─────────────────────────────────────────────────────────
log_info()    { echo -e "${BLUE}→${NC} $*"; }
log_ok()      { echo -e "${GREEN}✓${NC} $*"; }
log_fail()    { echo -e "${RED}✗${NC} $*"; }
log_warn()    { echo -e "${YELLOW}⚠${NC} $*"; }

banner() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║ $1${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Record an assertion failure for the current combo.
# Args: <missing artifact name> [detail]
fail() {
    local artifact="$1"
    local detail="${2:-}"
    echo -e "${RED}✗ [${COMBO_LABEL}] missing/failed artifact: ${artifact}${NC}"
    if [[ -n "$detail" ]]; then
        echo -e "    ${YELLOW}${detail}${NC}"
    fi
    COMBO_FAILURES=$((COMBO_FAILURES + 1))
}

# ── Cleanup ─────────────────────────────────────────────────────────────────
cleanup() {
    if [[ "${KEEP_OUTPUT:-0}" != "1" && -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

# ── Tool checks ─────────────────────────────────────────────────────────────
check_tools() {
    log_info "Checking tools..."

    if ! command -v cargo-generate &>/dev/null; then
        log_fail "cargo-generate is required but not installed"
        echo "  Install: cargo install cargo-generate --locked"
        exit 1
    fi
    log_ok "cargo-generate: $(command -v cargo-generate)"

    if command -v kustomize &>/dev/null; then
        KUSTOMIZE_BUILD=("kustomize" "build")
        log_ok "kustomize: $(command -v kustomize)"
    elif command -v kubectl &>/dev/null; then
        KUSTOMIZE_BUILD=("kubectl" "kustomize")
        log_warn "kustomize not found — falling back to kubectl kustomize"
    else
        log_fail "Neither kustomize nor kubectl is available (one is required for static manifest validation)"
        echo "  Install kustomize: brew install kustomize  (or download from sigs.k8s.io/kustomize)"
        exit 1
    fi

    if command -v python3 &>/dev/null && python3 -c "import yaml" &>/dev/null; then
        HAVE_PY3_YAML=1
        log_ok "python3 + PyYAML available (workflow YAML parse enabled)"
    else
        HAVE_PY3_YAML=0
        log_warn "python3 with PyYAML not available — workflow YAML parse degrades to grep sanity check"
    fi
}

# ── Template source preparation ─────────────────────────────────────────────
prepare_template_source() {
    log_info "Preparing template source copy (without .git/)..."
    TEMPLATE_COPY="$WORK_DIR/template-source"
    mkdir -p "$TEMPLATE_COPY"

    if command -v rsync &>/dev/null; then
        rsync -a --exclude='.git' --exclude='target' --exclude='.opencode' --exclude='.sisyphus' \
            "$PROJECT_ROOT/" "$TEMPLATE_COPY/"
    else
        cp -a "$PROJECT_ROOT/." "$TEMPLATE_COPY/"
        rm -rf "$TEMPLATE_COPY/.git" "$TEMPLATE_COPY/target" "$TEMPLATE_COPY/.opencode" "$TEMPLATE_COPY/.sisyphus"
    fi

    log_ok "Template source ready: $TEMPLATE_COPY"
}

# ── Generation ──────────────────────────────────────────────────────────────
generate_project() {
    local g="$1" i="$2" f="$3"
    local combo_dir="$WORK_DIR/combo-${g}-${i}-${f}"
    local values_file="$combo_dir/template-values.toml"

    mkdir -p "$combo_dir"

    # Base values: every placeholder covered (required by --silent mode).
    # The three matrix flags are also declared here (safe defaults) and
    # overridden via --define below (verified: --define wins over values file).
    cat > "$values_file" <<EOF
[values]
project_name = "${APP_NAME}"
project_author = "Prod Matrix <prod-matrix@local.dev>"
feature_s3 = false
feature_postgres = false
feature_kafka = false
feature_flagger = false
feature_gha_runner = false
event_source_kafka = false
enable_image_updates = false
target_namespace = "default"
github_org = "test-org"
github_repo = "test-repo"
default_branch = "main"
image_registry = "ghcr.io"
use_default_scaling = true
EOF

    # Constraint: --allow-commands must stay OFF — it would run the clippy/fmt
    # post-hook in all 8 generations. </dev/null guarantees no prompt hang.
    # cargo-generate bool placeholders reject "0"/"1" — pass true/false.
    local g_bool="false" i_bool="false" f_bool="false"
    [[ "$g" == "1" ]] && g_bool="true"
    [[ "$i" == "1" ]] && i_bool="true"
    [[ "$f" == "1" ]] && f_bool="true"

    cargo generate \
        --path "$TEMPLATE_COPY" \
        --name "$APP_NAME" \
        --values-file "$values_file" \
        --define "feature_gha_runner=$g_bool" \
        --define "enable_image_updates=$i_bool" \
        --define "feature_flagger=$f_bool" \
        --destination "$combo_dir" \
        --silent </dev/null
}

# ── Assertion helpers ───────────────────────────────────────────────────────
kust_build() {
    # Builds a kustomization dir; echoes output; returns the build's exit code.
    local dir="$1"
    "${KUSTOMIZE_BUILD[@]}" "${KUST_FLAGS[@]}" "$dir" 2>&1
}

assert_no_liquid_residue() {
    # Args: <name> <built-output>
    local name="$1" output="$2"
    if grep -qF '{%' <<<"$output"; then
        fail "${name} (liquid residue {% in rendered output)"
        return 1
    fi
    return 0
}

# ── Assertions ──────────────────────────────────────────────────────────────
assert_bash_syntax() {
    local f
    local script_errors=0
    for f in scripts/prod/deploy.sh scripts/prod/create-github-env.sh; do
        if [[ ! -f "$GEN_DIR/$f" ]]; then
            fail "$f (file missing)"
            script_errors=1
        elif ! bash -n "$GEN_DIR/$f" 2>/dev/null; then
            fail "$f (bash -n syntax check failed)"
            script_errors=1
        fi
    done
    return "$script_errors"
}

assert_flux_config_prod() {
    local errors=0
    local out
    if out="$(kust_build "$GEN_DIR/deploy/flux/config/prod")"; then
        log_ok "  kustomize build deploy/flux/config/prod"
    else
        fail "deploy/flux/config/prod (kustomize build failed)"
        echo "$out" | head -5 | sed 's/^/      /'
        errors=1
    fi
    assert_no_liquid_residue "deploy/flux/config/prod" "$out" || errors=1
    return "$errors"
}

assert_prod_namespace() {
    local errors=0
    local out
    if out="$(kust_build "$GEN_DIR/deploy/overlays/prod")"; then
        log_ok "  kustomize build deploy/overlays/prod"
    else
        fail "deploy/overlays/prod (kustomize build failed)"
        echo "$out" | head -5 | sed 's/^/      /'
        errors=1
    fi
    if ! grep -q 'namespace: production' <<<"$out"; then
        fail "deploy/overlays/prod (rendered output missing 'namespace: production')"
        errors=1
    fi
    if ! grep -q '^kind: Namespace' <<<"$out"; then
        fail "deploy/overlays/prod/namespace.yaml (rendered output missing a 'kind: Namespace' resource)"
        errors=1
    fi
    assert_no_liquid_residue "deploy/overlays/prod" "$out" || errors=1
    return "$errors"
}

assert_rbac() {
    # Args: <gha_runner flag> <image_updates flag>
    local g="$1" i="$2"
    local errors=0
    local dir="$GEN_DIR/deploy/infrastructure/gha-runner"
    local out sa_count rb_count

    if [[ "$g" != "1" ]]; then
        if [[ -e "$dir" ]]; then
            fail "deploy/infrastructure/gha-runner (dir must be ABSENT when feature_gha_runner=0)"
            errors=1
        fi
        return "$errors"
    fi

    if out="$(kust_build "$dir")"; then
        log_ok "  kustomize build deploy/infrastructure/gha-runner"
    else
        fail "deploy/infrastructure/gha-runner (kustomize build failed)"
        echo "$out" | head -5 | sed 's/^/      /'
        errors=1
    fi

    sa_count="$(grep -c '^kind: ServiceAccount' <<<"$out" || true)"
    if [[ "$sa_count" != "1" ]]; then
        fail "deploy/infrastructure/gha-runner/rbac.yaml (expected exactly 1 'kind: ServiceAccount', found ${sa_count:-0})"
        errors=1
    fi

    rb_count="$(grep -c '^kind: RoleBinding' <<<"$out" || true)"
    if [[ "$rb_count" != "2" ]]; then
        fail "deploy/infrastructure/gha-runner/rbac.yaml (expected exactly 2 'kind: RoleBinding', found ${rb_count:-0})"
        errors=1
    fi

    # RBAC consistency: every RoleBinding subject must reference the runner SA's
    # namespace (actions-runner-system) — ARC creates runner pods there.
    local bad_bindings
    bad_bindings="$(awk '
        /^---$/                      { if (inrb && !found) bad++; inrb=0; found=0; next }
        /^kind: RoleBinding/         { if (inrb && !found) bad++; inrb=1; found=0; next }
        inrb && /namespace: actions-runner-system/ { found=1 }
        END { if (inrb && !found) bad++; print bad+0 }
    ' <<<"$out")"
    if [[ "$bad_bindings" != "0" ]]; then
        fail "deploy/infrastructure/gha-runner/rbac.yaml (${bad_bindings} RoleBinding(s) without subjects[].namespace: actions-runner-system)"
        errors=1
    fi

    # Conditional image-automation CR rules (Task 4: {% if enable_image_updates %})
    if [[ "$i" == "1" ]]; then
        if ! grep -q 'imageupdateautomations' <<<"$out"; then
            fail "deploy/infrastructure/gha-runner/rbac.yaml (enable_image_updates=1 but rendered Role missing 'imageupdateautomations' rules)"
            errors=1
        fi
    else
        if grep -q 'imageupdateautomations' <<<"$out"; then
            fail "deploy/infrastructure/gha-runner/rbac.yaml (enable_image_updates=0 but rendered Role contains 'imageupdateautomations' rules)"
            errors=1
        fi
    fi

    assert_no_liquid_residue "deploy/infrastructure/gha-runner" "$out" || errors=1
    return "$errors"
}

assert_workflow() {
    local errors=0
    local wf="$GEN_DIR/.github/workflows/deploy.yaml"
    local grep_check

    if [[ ! -f "$wf" ]]; then
        fail ".github/workflows/deploy.yaml (rendered workflow file missing)"
        return 1
    fi

    if [[ "$HAVE_PY3_YAML" -eq 1 ]]; then
        if ! python3 -c "import sys, yaml; yaml.safe_load(open(sys.argv[1]))" "$wf" &>/dev/null; then
            fail ".github/workflows/deploy.yaml (python3 yaml.safe_load parse failed)"
            errors=1
        fi
    else
        log_warn "  python3/PyYAML unavailable — grep sanity check instead of YAML parse"
        grep_check="$(grep -c 'environment: production' "$wf" || true)"
        if [[ "$grep_check" -lt 1 ]]; then
            fail ".github/workflows/deploy.yaml (grep sanity check: 'environment: production' missing)"
            errors=1
        fi
    fi

    # Structural grep assertions
    if ! grep -q 'environment: production' "$wf"; then
        fail ".github/workflows/deploy.yaml (missing 'environment: production')"
        errors=1
    fi
    if ! grep -q '^concurrency:' "$wf" && ! grep -q '^[[:space:]]*concurrency:' "$wf"; then
        fail ".github/workflows/deploy.yaml (missing 'concurrency:')"
        errors=1
    fi
    if ! grep -q 'cancel-in-progress: false' "$wf"; then
        fail ".github/workflows/deploy.yaml (missing 'cancel-in-progress: false' — deploys queue, never cancel)"
        errors=1
    fi
    if ! grep -q '^permissions:' "$wf" && ! grep -q '^[[:space:]]*permissions:' "$wf"; then
        fail ".github/workflows/deploy.yaml (missing 'permissions:')"
        errors=1
    fi
    if ! grep -q 'timeout-minutes: 45' "$wf"; then
        fail ".github/workflows/deploy.yaml (missing 'timeout-minutes: 45')"
        errors=1
    fi
    if ! grep -q 'make prod-deploy' "$wf"; then
        fail ".github/workflows/deploy.yaml (missing 'make prod-deploy' invocation)"
        errors=1
    fi
    if grep -q '@latest' "$wf"; then
        fail ".github/workflows/deploy.yaml (tool versions must be pinned — found '@latest')"
        errors=1
    fi

    return "$errors"
}

assert_makefile_targets() {
    local errors=0
    local mk="$GEN_DIR/Makefile"
    local needle

    if [[ ! -f "$mk" ]]; then
        fail "Makefile (missing in generated project)"
        return 1
    fi

    for needle in 'prod-deploy:' 'prod-github-env:' 'prod-kubeconfig:' 'PROD_KUBECONFIG_PATH' 'GITHUB_ORG'; do
        if ! grep -q "$needle" "$mk"; then
            fail "Makefile (missing '$needle')"
            errors=1
        fi
    done
    return "$errors"
}

assert_gitrepository_ssh() {
    local errors=0
    local gr="$GEN_DIR/deploy/flux/git-repository.yaml"

    if [[ ! -f "$gr" ]]; then
        fail "deploy/flux/git-repository.yaml (missing in generated project)"
        return 1
    fi

    # URL must be SSH (uncommented)
    if ! grep -Eq '^[[:space:]]*url:[[:space:]]*ssh://git@github\.com' "$gr"; then
        fail "deploy/flux/git-repository.yaml (spec.url must be an uncommented 'ssh://git@github.com' URL)"
        errors=1
    fi

    # secretRef must be active (not commented) and name the deploy key
    if ! grep -Eq '^[[:space:]]*secretRef:' "$gr"; then
        fail "deploy/flux/git-repository.yaml (secretRef: is commented out — must be active YAML)"
        errors=1
    elif ! grep -A2 '^[[:space:]]*secretRef:' "$gr" | grep -q 'name: github-deploy-key'; then
        fail "deploy/flux/git-repository.yaml (secretRef does not reference 'name: github-deploy-key')"
        errors=1
    fi

    return "$errors"
}

# ── Per-combo runner ────────────────────────────────────────────────────────
run_combo() {
    local g="$1" i="$2" f="$3"
    COMBO_LABEL="gha_runner=${g} image_updates=${i} flagger=${f}"
    COMBO_FAILURES=0
    TOTAL_COMBOS=$((TOTAL_COMBOS + 1))

    local combo_dir="$WORK_DIR/combo-${g}-${i}-${f}"
    banner "Combo ${TOTAL_COMBOS}: ${COMBO_LABEL}  |  dir: ${combo_dir}"

    log_info "Generating template..."
    if ! generate_project "$g" "$i" "$f"; then
        fail "cargo generate (template generation failed for combo ${COMBO_LABEL})"
        tally_combo
        return 1
    fi
    GEN_DIR="$combo_dir/$APP_NAME"
    log_ok "Generated: $GEN_DIR"

    log_info "Running assertions..."
    assert_bash_syntax      || true
    assert_flux_config_prod || true
    assert_prod_namespace   || true
    assert_rbac "$g" "$i"   || true
    assert_workflow         || true
    assert_makefile_targets || true
    assert_gitrepository_ssh || true

    tally_combo
}

tally_combo() {
    if [[ "$COMBO_FAILURES" -eq 0 ]]; then
        PASSED_COMBOS=$((PASSED_COMBOS + 1))
        log_ok "Combo PASSED: ${COMBO_LABEL}"
    else
        FAILED_COMBOS=$((FAILED_COMBOS + 1))
        FAILED_LIST+=("${COMBO_LABEL} (${COMBO_FAILURES} failed assertion(s))")
        log_fail "Combo FAILED: ${COMBO_LABEL} (${COMBO_FAILURES} failed assertion(s))"
    fi
}

# ── Matrix resolution ───────────────────────────────────────────────────────
resolve_combos() {
    # Populates the global COMBOS array.
    COMBOS=()
    if [[ -n "$MATRIX" ]]; then
        local g i f
        IFS=',' read -r g i f <<<"$MATRIX"
        for v in "$g" "$i" "$f"; do
            if [[ "$v" != "0" && "$v" != "1" ]]; then
                log_fail "Invalid PROD_DEPLOY_MATRIX='${MATRIX}' — expected comma-separated 0/1 flags: gha_runner,image_updates,flagger (e.g. \"0,0,0\")"
                exit 1
            fi
        done
        COMBOS=("${g},${i},${f}")
        log_info "Single-combo mode: PROD_DEPLOY_MATRIX=${MATRIX}"
    else
        local g i f
        for g in 0 1; do
            for i in 0 1; do
                for f in 0 1; do
                    COMBOS+=("${g},${i},${f}")
                done
            done
        done
        log_info "Full matrix mode: ${#COMBOS[@]} combos (gha_runner × image_updates × flagger)"
    fi
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    banner "Prod Deploy Static Validation Harness (TDD red gate)"
    log_info "Template: ${PROJECT_ROOT}"
    log_info "Generated project name: ${APP_NAME}"

    check_tools

    WORK_DIR="$(mktemp -d)"
    log_info "Working directory: ${WORK_DIR}"
    if [[ "${KEEP_OUTPUT:-0}" == "1" ]]; then
        log_info "(output will be preserved after the run)"
    fi

    prepare_template_source

    local COMBOS=()
    resolve_combos
    echo ""

    for combo in "${COMBOS[@]}"; do
        IFS=',' read -r g i f <<<"$combo"
        run_combo "$g" "$i" "$f" || true
        echo ""
    done

    # ── Summary ──
    banner "Results: ${PASSED_COMBOS}/${TOTAL_COMBOS} combos passed"
    if [[ ${#FAILED_LIST[@]} -gt 0 ]]; then
        echo -e "${RED}Failed combos:${NC}"
        for entry in "${FAILED_LIST[@]}"; do
            echo -e "  ${RED}-${NC} $entry"
        done
        echo ""
    fi

    if [[ "$FAILED_COMBOS" -eq 0 ]]; then
        log_ok "All ${TOTAL_COMBOS} combo(s) passed — prod deploy tooling is consistent."
        exit 0
    else
        log_fail "${FAILED_COMBOS}/${TOTAL_COMBOS} combo(s) failed — see missing artifacts above."
        exit 1
    fi
}

main "$@"
