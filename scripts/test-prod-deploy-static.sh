#!/bin/bash
#
# test-prod-deploy-static.sh — Static validation suite for prod deploy tooling
#
# Generates this cargo-generate template into temp dirs across a feature-flag
# matrix and asserts on the generated output (pure static validation — NO
# Kubernetes cluster needed). Maintained as the fast gate for prod-deploy
# tooling: run it after touching scripts/prod/*, deploy/overlays/*,
# deploy/flux/*, or deploy/infrastructure/gha-runner.
#
# Asserted artifacts:
#   scripts/prod/deploy.sh                 (kubectl auth can-i preflight, sources
#                                          deploy-key.sh, no dead 'then :; fi')
#   scripts/prod/deploy-key.sh             (exists, bash -n clean)
#   scripts/prod/create-github-env.sh      (no jq; DEFAULT_BRANCH_PATTERN derived
#                                          from deploy/flux/git-repository.yaml)
#   Makefile prod-* targets + vars
#   deploy/flux/git-repository.yaml SSH + secretRef
#   deploy/flux/config/{dev,staging,prod}  kustomize builds + no liquid residue
#   deploy/overlays/{dev,staging,prod}     kustomize builds + no liquid residue
#                                          (staging/prod also render a Namespace)
#   deploy/infrastructure/gha-runner RBAC  (1 ServiceAccount, 3 RoleBindings, all
#                                          subjects in actions-runner-system;
#                                          hooks Role grants pods/exec + jobs +
#                                          secrets; events rule grants get+list;
#                                          flux-system Role grants NO helmcharts;
#                                          NO ksvc anywhere; production Role
#                                          grants helmreleases get/list/watch)
#   .github/workflows/deploy.yaml          (rendered workflow structure)
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
#   (optional — enables YAML-parsed RBAC checks and workflow YAML parse; both
#   degrade to section-aware grep/awk sanity checks without it)
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
#     deploy/flux/config/* references ../../kustomization-<env>.yaml, which
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
    for f in scripts/prod/deploy.sh scripts/prod/deploy-key.sh scripts/prod/create-github-env.sh; do
        if [[ ! -f "$GEN_DIR/$f" ]]; then
            fail "$f (file missing)"
            script_errors=1
        elif ! bash -n "$GEN_DIR/$f" 2>/dev/null; then
            fail "$f (bash -n syntax check failed)"
            script_errors=1
        fi
    done

    local dep="$GEN_DIR/scripts/prod/deploy.sh"
    if [[ -f "$dep" ]]; then
        if ! grep -q 'kubectl auth can-i' "$dep"; then
            fail "scripts/prod/deploy.sh (missing 'kubectl auth can-i' preflight — C1 regression guard)"
            script_errors=1
        fi
        if ! grep -Eq '(source|\.[[:space:]])[[:space:]]*.*deploy-key\.sh' "$dep"; then
            fail "scripts/prod/deploy.sh (must source scripts/prod/deploy-key.sh)"
            script_errors=1
        fi
        if grep -q 'then :; fi' "$dep"; then
            fail "scripts/prod/deploy.sh (contains dead pattern 'then :; fi')"
            script_errors=1
        fi
    fi

    local cge="$GEN_DIR/scripts/prod/create-github-env.sh"
    if [[ -f "$cge" ]]; then
        if grep -Eq '\bjq\b' "$cge"; then
            fail "scripts/prod/create-github-env.sh (must not invoke jq — parse deploy/flux/git-repository.yaml with awk/sed)"
            script_errors=1
        fi
        if ! grep -q 'deploy/flux/git-repository.yaml' "$cge"; then
            fail "scripts/prod/create-github-env.sh (missing DEFAULT_BRANCH_PATTERN derivation: must read deploy/flux/git-repository.yaml)"
            script_errors=1
        fi
        if ! grep -q 'DEFAULT_BRANCH_PATTERN' "$cge"; then
            fail "scripts/prod/create-github-env.sh (missing DEFAULT_BRANCH_PATTERN variable)"
            script_errors=1
        elif ! grep -Eq 'DEFAULT_BRANCH_PATTERN.*(:-|:=|\?=)' "$cge"; then
            fail "scripts/prod/create-github-env.sh (DEFAULT_BRANCH_PATTERN lacks a default fallback, e.g. ':-main')"
            script_errors=1
        fi
    fi

    return "$script_errors"
}

# Build a kustomization dir; assert build success, no liquid residue, and that
# each extra arg (a grep pattern) appears in the rendered output.
assert_kust_dir() {
    # Args: <display path> <dir> [required-output-pattern...]
    local display="$1" dir="$2"
    shift 2
    local errors=0
    local out pattern
    if out="$(kust_build "$dir")"; then
        log_ok "  kustomize build $display"
    else
        fail "$display (kustomize build failed)"
        echo "$out" | head -5 | sed 's/^/      /'
        errors=1
    fi
    assert_no_liquid_residue "$display" "$out" || errors=1
    for pattern in "$@"; do
        if ! grep -q "$pattern" <<<"$out"; then
            fail "$display (rendered output missing '$pattern')"
            errors=1
        fi
    done
    return "$errors"
}

assert_flux_config_prod() {
    assert_kust_dir "deploy/flux/config/prod" "$GEN_DIR/deploy/flux/config/prod"
}

assert_flux_config_dev() {
    assert_kust_dir "deploy/flux/config/dev" "$GEN_DIR/deploy/flux/config/dev"
}

assert_flux_config_staging() {
    assert_kust_dir "deploy/flux/config/staging" "$GEN_DIR/deploy/flux/config/staging"
}

assert_prod_namespace() {
    assert_kust_dir "deploy/overlays/prod" "$GEN_DIR/deploy/overlays/prod" \
        'namespace: production' '^kind: Namespace'
}

assert_overlay_dev() {
    assert_kust_dir "deploy/overlays/dev" "$GEN_DIR/deploy/overlays/dev"
}

assert_overlay_staging() {
    assert_kust_dir "deploy/overlays/staging" "$GEN_DIR/deploy/overlays/staging" '^kind: Namespace'
}

# Semantic RBAC checks on the rendered gha-runner output (Role rule resources
# and verbs). Prefers python3+PyYAML; falls back to section-aware awk.
_rbac_yaml_checks() {
    # Args: <rendered gha-runner kustomize output>
    local out="$1"
    local findings rc=0

    if [[ "$HAVE_PY3_YAML" -eq 1 ]]; then
        findings="$(printf '%s' "$out" | python3 -c '
import sys, yaml

docs = [d for d in yaml.safe_load_all(sys.stdin) if isinstance(d, dict)]
errors = []

def ns_of(doc):
    return (doc.get("metadata") or {}).get("namespace") or ""

def rule_resources(rule):
    return rule.get("resources") or []

def rule_verbs(rule):
    return set(rule.get("verbs") or [])

roles = [d for d in docs if d.get("kind") == "Role"]

ars = [r for r in roles if ns_of(r) == "actions-runner-system"]
if not ars:
    errors.append("no Role with metadata.namespace: actions-runner-system")
else:
    res = set()
    for r in ars:
        for rule in r.get("rules") or []:
            res.update(rule_resources(rule))
    for need in ("pods/exec", "jobs", "secrets"):
        if need not in res:
            errors.append("actions-runner-system Role missing resource: " + need)

events_ok = False
for r in roles:
    for rule in r.get("rules") or []:
        if any("events" in x for x in rule_resources(rule)):
            v = rule_verbs(rule)
            if "get" in v and "list" in v:
                events_ok = True
if not events_ok:
    errors.append("no Role grants both get and list on events")

for r in roles:
    if ns_of(r) == "flux-system":
        for rule in r.get("rules") or []:
            if "helmcharts" in rule_resources(rule):
                errors.append("flux-system Role still grants helmcharts (must be removed)")

hr_ok = False
for r in roles:
    if ns_of(r) != "production":
        continue
    for rule in r.get("rules") or []:
        if "helmreleases" in rule_resources(rule) and {"get", "list", "watch"} <= rule_verbs(rule):
            hr_ok = True
if not hr_ok:
    errors.append("no production-namespace Role grants helmreleases with get/list/watch")

if errors:
    print("\n".join(errors))
    sys.exit(1)
')" || rc=1
        if [[ "$rc" -eq 0 ]]; then
            return 0
        fi
        if [[ -n "$findings" ]]; then
            local line
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                fail "deploy/infrastructure/gha-runner/rbac.yaml ($line)"
            done <<<"$findings"
        else
            fail "deploy/infrastructure/gha-runner/rbac.yaml (python3 RBAC parse crashed — see stderr above)"
        fi
        return 1
    fi

    # Fallback: section-aware awk (no PyYAML). One finding code per line.
    findings="$(awk '
        function rule_flush() {
            if (kind != "Role") { rres = ""; rverbs = ""; return }
            if (rres ~ /(^|[[:space:]])events([[:space:]]|$)/ &&
                rverbs ~ /(^|[[:space:]])get([[:space:]]|$)/ &&
                rverbs ~ /(^|[[:space:]])list([[:space:]]|$)/) events_ok = 1
            if (ns == "production" &&
                rres ~ /(^|[[:space:]])helmreleases([[:space:]]|$)/ &&
                rverbs ~ /(^|[[:space:]])get([[:space:]]|$)/ &&
                rverbs ~ /(^|[[:space:]])list([[:space:]]|$)/ &&
                rverbs ~ /(^|[[:space:]])watch([[:space:]]|$)/) prod_ok = 1
            rres = ""; rverbs = ""
        }
        function doc_flush() {
            rule_flush()
            if (kind == "Role" && ns == "actions-runner-system") {
                ars_found = 1
                if (have_exec && have_jobs && have_secrets) ars_ok = 1
            }
            kind = ""; ns = ""; have_exec = 0; have_jobs = 0; have_secrets = 0; inrules = 0
        }
        BEGIN { ars_found = 0; ars_ok = 0; events_ok = 0; prod_ok = 0; flux_bad = 0 }
        /^---/                              { doc_flush(); next }
        /^kind: Role$/                      { kind = "Role"; next }
        /^kind: RoleBinding/                { kind = "RoleBinding"; next }
        /^kind: ServiceAccount/             { kind = "ServiceAccount"; next }
        /^[[:space:]]+namespace: actions-runner-system/ { ns = "actions-runner-system"; next }
        /^[[:space:]]+namespace: flux-system/           { ns = "flux-system"; next }
        /^[[:space:]]+namespace: production/            { ns = "production"; next }
        kind == "Role" && ns == "flux-system" && /helmcharts/ { flux_bad = 1 }
        kind == "Role" && ns == "actions-runner-system" && /pods\/exec/ { have_exec = 1 }
        kind == "Role" && ns == "actions-runner-system" && /^[[:space:]]+- jobs$/    { have_jobs = 1 }
        kind == "Role" && ns == "actions-runner-system" && /^[[:space:]]+- secrets$/ { have_secrets = 1 }
        kind == "Role" && /^[[:space:]]*rules:/          { inrules = 1; next }
        kind == "Role" && inrules && /^[[:space:]]*- apiGroups:/ { rule_flush(); next }
        kind == "Role" && inrules && /^[[:space:]]*resources:/   { sec = "res"; next }
        kind == "Role" && inrules && /^[[:space:]]*verbs:/       { sec = "verbs"; next }
        kind == "Role" && inrules && /^[[:space:]]*apiGroups:/   { sec = "api"; next }
        kind == "Role" && inrules && sec == "res"   && /^[[:space:]]+- / { rres = rres " " $2 }
        kind == "Role" && inrules && sec == "verbs" && /^[[:space:]]+- / { rverbs = rverbs " " $2 }
        END {
            doc_flush()
            if (!ars_found) print "NO_ARS_ROLE"
            if (!ars_ok)    print "ARS_MISSING_RESOURCES"
            if (!events_ok) print "EVENTS_GET_LIST_MISSING"
            if (flux_bad)   print "FLUX_HELMCHARTS_PRESENT"
            if (!prod_ok)   print "PROD_HELMRELEASES_MISSING"
        }
    ' <<<"$out")"

    local code
    local errors=0
    while IFS= read -r code; do
        [[ -z "$code" ]] && continue
        case "$code" in
            NO_ARS_ROLE)               fail "deploy/infrastructure/gha-runner/rbac.yaml (no Role with metadata.namespace: actions-runner-system found in rendered output)" ;;
            ARS_MISSING_RESOURCES)     fail "deploy/infrastructure/gha-runner/rbac.yaml (actions-runner-system Role missing pods/exec, jobs, or secrets resources)" ;;
            EVENTS_GET_LIST_MISSING)   fail "deploy/infrastructure/gha-runner/rbac.yaml (no Role grants both 'get' and 'list' on events)" ;;
            FLUX_HELMCHARTS_PRESENT)   fail "deploy/infrastructure/gha-runner/rbac.yaml (flux-system Role still grants 'helmcharts' — must be removed)" ;;
            PROD_HELMRELEASES_MISSING) fail "deploy/infrastructure/gha-runner/rbac.yaml (no production-namespace Role grants 'helmreleases' with get/list/watch)" ;;
        esac
        errors=1
    done <<<"$findings"
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
    if [[ "$rb_count" != "3" ]]; then
        fail "deploy/infrastructure/gha-runner/rbac.yaml (expected exactly 3 'kind: RoleBinding', found ${rb_count:-0})"
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

    # Role-rule semantics: hooks Role resources, events get+list, flux-system
    # helmcharts absence, production helmreleases get/list/watch.
    _rbac_yaml_checks "$out" || errors=1

    # ksvc must not appear: Knative reads go through the production Role's
    # serving.knative.dev services rule instead.
    if grep -q 'ksvc' <<<"$out"; then
        fail "deploy/infrastructure/gha-runner/rbac.yaml (rendered output contains 'ksvc' — grant must not exist)"
        errors=1
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
    assert_bash_syntax          || true
    assert_flux_config_prod     || true
    assert_flux_config_dev      || true
    assert_flux_config_staging  || true
    assert_prod_namespace       || true
    assert_overlay_dev          || true
    assert_overlay_staging      || true
    assert_rbac "$g" "$i"       || true
    assert_workflow             || true
    assert_makefile_targets     || true
    assert_gitrepository_ssh    || true

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
    banner "Prod Deploy Static Validation Suite"
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
