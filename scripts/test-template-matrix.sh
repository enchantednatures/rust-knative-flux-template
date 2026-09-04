#!/usr/bin/env bash
#
# test-template-matrix.sh — Local template matrix validation
#
# Generates the template for every feature combination and validates:
#   1. cargo-generate succeeds (template renders without errors)
#   2. Generated deploy/ structure is correct (components present/absent)
#   3. kustomize build succeeds for all overlays (YAML is valid)
#   4. cargo fmt / clippy / build / test --no-run pass
#
# Usage:
#   ./scripts/test-template-matrix.sh              # Run full matrix (all combos)
#   ./scripts/test-template-matrix.sh --quick       # Skip Rust build, only validate structure + kustomize
#   ./scripts/test-template-matrix.sh --scenario 5  # Run a single scenario by number
#   ./scripts/test-template-matrix.sh --list        # List all scenarios
#   ./scripts/test-template-matrix.sh --parallel 4  # Run up to N scenarios concurrently
#
# Prerequisites:
#   cargo-generate, kustomize (optional), cargo + rustc (unless --quick)
#
# Environment:
#   TEMPLATE_DIR    Override template source (default: repo root)
#   KEEP_OUTPUT     Set to "1" to preserve generated projects after run
#

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Globals ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="${TEMPLATE_DIR:-$REPO_ROOT}"
TEMPLATE_SOURCE_DIR=""  # Set in main() after copying without .git/
WORK_DIR=""
QUICK=false
PARALLEL=1
SINGLE_SCENARIO=""
LIST_ONLY=false

TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0
FAILED_SCENARIOS=()
START_TIME=$(date +%s)

# ── Matrix definition ──────────────────────────────────────────────────────
# Each scenario is: "label|feature_s3|feature_kafka|feature_postgres|event_source_kafka|enable_image_updates"
#
# We test the 3 independent feature axes that affect deploy/ structure:
#   feature_s3, feature_postgres, feature_kafka  (3 booleans → 8 combos)
#   event_source_kafka                           (tied to feature_kafka for simplicity)
#   enable_image_updates: true/false             (only 2 combos worth testing with one feature set)
#
# Total: 8 core combos + 1 image-updates variant = 9 scenarios
#
SCENARIOS=(
  "bare|false|false|false|false|false"
  "s3-only|true|false|false|false|false"
  "kafka-only|false|true|false|true|false"
  "postgres-only|false|false|true|false|false"
  "s3-kafka|true|true|false|true|false"
  "s3-postgres|true|false|true|false|false"
  "kafka-postgres|false|true|true|true|false"
  "all-features|true|true|true|true|false"
  "all-features-img|true|true|true|true|true"
)

# Postgres-specific template values (only used when postgres feature is enabled)
POSTGRES_VALUES='
postgres_version = "16"
postgres_instances_dev = "1"
postgres_instances_staging = "2"
postgres_instances_prod = "3"
postgres_storage_class = "standard"
backup_schedule = "0 2 * * *"
backup_retention_dev = "7"
backup_retention_staging = "14"
backup_retention_prod = "30"
'

# Kafka-related template values (shared between feature_kafka and event_source_kafka)
# kafka_topic is used by both contexts, so it's always included when either is true
KAFKA_COMMON_VALUES='
kafka_topic = "events"
'

# Kafka event_source-specific template values
KAFKA_EVENT_SOURCE_VALUES='
kafka_consumer_group = "test-app-consumers"
kafka_bootstrap_servers_staging = "kafka.staging.svc.cluster.local:9092"
kafka_bootstrap_servers_prod = "kafka.prod.svc.cluster.local:9092"
'

# Kafka feature-specific template values
KAFKA_FEATURE_VALUES='
kafka_broker_url = "kafka.kafka.svc.cluster.local:9092"
kafka_event_name = "com.test-app.event.published"
'

# ── Helpers ─────────────────────────────────────────────────────────────────
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[  OK]${NC}  $*"; }
log_fail()    { echo -e "${RED}[FAIL]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_skip()    { echo -e "${DIM}[SKIP]${NC}  $*"; }
log_header()  {
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  $*${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

cleanup() {
  if [[ "${KEEP_OUTPUT:-0}" != "1" && -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
  # Clean up template source copy (unless --keep is set, for debugging)
  if [[ "${KEEP_OUTPUT:-0}" != "1" && -n "$TEMPLATE_SOURCE_DIR" && -d "$TEMPLATE_SOURCE_DIR" && "$TEMPLATE_SOURCE_DIR" == /tmp/* ]]; then
    rm -rf "$TEMPLATE_SOURCE_DIR"
  fi
}
trap cleanup EXIT

# ── Argument parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --quick|-q)    QUICK=true; shift ;;
    --scenario|-s) SINGLE_SCENARIO="$2"; shift 2 ;;
    --list|-l)     LIST_ONLY=true; shift ;;
    --parallel|-p) PARALLEL="$2"; shift 2 ;;
    --keep)        export KEEP_OUTPUT=1; shift ;;
    --help|-h)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --quick, -q          Skip Rust build/lint, only validate structure + kustomize"
      echo "  --scenario N, -s N   Run only scenario N (1-based index)"
      echo "  --list, -l           List all scenarios and exit"
      echo "  --parallel N, -p N   Run up to N scenarios concurrently (default: 1)"
      echo "  --keep               Preserve generated output directories"
      echo "  --help, -h           Show this help"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── List mode ───────────────────────────────────────────────────────────────
if $LIST_ONLY; then
  echo "Available scenarios:"
  echo ""
  for i in "${!SCENARIOS[@]}"; do
    IFS='|' read -r label f_s3 f_kafka f_postgres es_kafka img_updates <<< "${SCENARIOS[$i]}"
    printf "  %2d. %-22s s3=%-6s kafka=%-6s postgres=%-6s es_kafka=%-6s img=%s\n" \
      $((i+1)) "$label" "$f_s3" "$f_kafka" "$f_postgres" "$es_kafka" "$img_updates"
  done
  exit 0
fi

# ── Preflight ───────────────────────────────────────────────────────────────
check_prerequisites() {
  local missing=()

  if ! command -v cargo-generate &>/dev/null; then
    missing+=("cargo-generate")
  fi

  if ! $QUICK; then
    for cmd in cargo rustc; do
      if ! command -v "$cmd" &>/dev/null; then
        missing+=("$cmd")
      fi
    done
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_fail "Missing prerequisites: ${missing[*]}"
    echo ""
    echo "Install:"
    echo "  cargo-generate:  cargo install cargo-generate --locked"
    echo "  kustomize:       brew install kustomize  (or: go install sigs.k8s.io/kustomize/kustomize/v5@latest)"
    exit 1
  fi

  # Check optional kustomize
  if ! command -v kustomize &>/dev/null; then
    log_warn "kustomize not found -- will skip kustomize build validation"
  fi
}

# ── Prepare template source ────────────────────────────────────────────────
# cargo-generate --path reads from the git index when inside a git repo,
# NOT the working tree. This means uncommitted/untracked files are invisible.
# Solution: copy the working tree to a temp dir without .git/.
prepare_template_source() {
  local src="$1" dest="$2"

  log_info "Preparing template source (copying without .git/)..."

  # Use rsync if available (faster, respects .gitignore-like excludes)
  # Otherwise fall back to cp + rm
  if command -v rsync &>/dev/null; then
    rsync -a --exclude='.git' --exclude='target' "$src/" "$dest/"
  else
    cp -a "$src/." "$dest/"
    rm -rf "$dest/.git" "$dest/target"
  fi

  log_ok "Template source ready at: $dest"
}

# ── Template generation ─────────────────────────────────────────────────────
generate_project() {
  local label="$1" f_s3="$2" f_kafka="$3" f_postgres="$4" es_kafka="$5" img_updates="$6" out_dir="$7"

  # Build template-values.toml
  local values_file="$out_dir/template-values.toml"
  mkdir -p "$out_dir"
  cat > "$values_file" <<EOF
[values]
project_name = "test-app"
project_author = "Matrix Test <test@local>"
feature_s3 = $f_s3
feature_kafka = $f_kafka
feature_postgres = $f_postgres
feature_flagger = false
event_source_kafka = $es_kafka
enable_image_updates = $img_updates
target_namespace = "default"
github_org = "test-org"
github_repo = "test-repo"
default_branch = "main"
image_registry = "ghcr.io"
use_default_scaling = true
EOF

  # Add conditional values based on features
  if [[ "$f_postgres" == "true" ]]; then
    echo "$POSTGRES_VALUES" >> "$values_file"
  fi
  # kafka_topic is shared between feature_kafka and event_source_kafka
  if [[ "$es_kafka" == "true" || "$f_kafka" == "true" ]]; then
    echo "$KAFKA_COMMON_VALUES" >> "$values_file"
  fi
  if [[ "$es_kafka" == "true" ]]; then
    echo "$KAFKA_EVENT_SOURCE_VALUES" >> "$values_file"
  fi
  if [[ "$f_kafka" == "true" ]]; then
    echo "$KAFKA_FEATURE_VALUES" >> "$values_file"
  fi

  # Use the .git-free template copy (TEMPLATE_SOURCE_DIR is set in main())
  cargo generate \
    --path "$TEMPLATE_SOURCE_DIR" \
    --name "test-app-${label}" \
    --template-values-file "$values_file" \
    --destination "$out_dir" \
    --silent \
    --allow-commands 2>&1
}

# ── Validation checks ──────────────────────────────────────────────────────

# Check that expected files/dirs exist (or don't exist)
validate_structure() {
  local dir="$1" f_s3="$2" f_kafka="$3" f_postgres="$4" es_kafka="$5" img_updates="$6"
  local errors=0

  # ── Always present ──
  local always_present=(
    "Cargo.toml"
    "src/main.rs"
    "deploy/base/kustomization.yaml"
    "deploy/base/knative-service.yaml"
    "deploy/overlays/dev/kustomization.yaml"
    "deploy/overlays/staging/kustomization.yaml"
    "deploy/overlays/prod/kustomization.yaml"
    "deploy/flux/git-repository.yaml"
    "deploy/flux/kustomization-dev.yaml"
    "deploy/flux/kustomization-staging.yaml"
    "deploy/flux/kustomization-prod.yaml"
    "deploy/flux/image-repository.yaml"
  )
  for f in "${always_present[@]}"; do
    if [[ ! -e "$dir/$f" ]]; then
      log_fail "  Missing expected file: $f"
      ((errors++))
    fi
  done

  # ── Postgres component ──
  if [[ "$f_postgres" == "true" ]]; then
    local pg_expected=(
      "deploy/components/postgres/kustomization.yaml"
      "deploy/components/postgres/postgres-cluster.yaml"
      "deploy/components/postgres/postgres-backup.yaml"
      "deploy/components/postgres/postgres-objectstore.yaml"
      "deploy/components/postgres/postgres-pooler.yaml"
      "deploy/components/postgres/postgres-podmonitor.yaml"
      "deploy/components/postgres/postgres-alerts.yaml"
      "deploy/components/operator/kustomization.yaml"
      "deploy/overlays/dev/postgres-cluster-patch.yaml"
      "deploy/overlays/dev/postgres-backup-patch.yaml"
      "deploy/overlays/staging/postgres-cluster-patch.yaml"
      "deploy/overlays/staging/postgres-backup-patch.yaml"
      "deploy/overlays/prod/postgres-cluster-patch.yaml"
      "deploy/overlays/prod/postgres-backup-patch.yaml"
      "deploy/flux/postgres-kustomization.yaml"
      "deploy/flux/git-repository-postgres.yaml"
    )
    for f in "${pg_expected[@]}"; do
      if [[ ! -e "$dir/$f" ]]; then
        log_fail "  Postgres enabled but missing: $f"
        ((errors++))
      fi
    done
  else
    local pg_absent=(
      "deploy/components/postgres"
      "deploy/components/operator"
      "deploy/flux/postgres-kustomization.yaml"
      "deploy/flux/git-repository-postgres.yaml"
    )
    for f in "${pg_absent[@]}"; do
      if [[ -e "$dir/$f" ]]; then
        log_fail "  Postgres disabled but present: $f"
        ((errors++))
      fi
    done
  fi

  # ── Kafka component ──
  if [[ "$es_kafka" == "true" ]]; then
    local kafka_expected=(
      "deploy/components/kafka/kustomization.yaml"
      "deploy/components/kafka/kafka-source.yaml"
      "deploy/components/kafka/dlq-handler.yaml"
      "deploy/overlays/dev/kafka-source-patch.yaml"
      "deploy/overlays/staging/kafka-source-patch.yaml"
      "deploy/overlays/prod/kafka-source-patch.yaml"
    )
    for f in "${kafka_expected[@]}"; do
      if [[ ! -e "$dir/$f" ]]; then
        log_fail "  Kafka event_source enabled but missing: $f"
        ((errors++))
      fi
    done
  else
    local kafka_absent=(
      "deploy/components/kafka"
      "deploy/overlays/dev/kafka-source-patch.yaml"
      "deploy/overlays/staging/kafka-source-patch.yaml"
      "deploy/overlays/prod/kafka-source-patch.yaml"
    )
    for f in "${kafka_absent[@]}"; do
      if [[ -e "$dir/$f" ]]; then
        log_fail "  Kafka event_source disabled but present: $f"
        ((errors++))
      fi
    done
  fi

  # ── Redundant paths should NEVER exist ──
  local never_present=(
    "deploy/infrastructure/cloudnative-pg"
    "deploy/base/postgres-cluster.yaml"
    "deploy/base/postgres-backup.yaml"
    "deploy/base/postgres-objectstore.yaml"
    "deploy/base/postgres-pooler.yaml"
    "deploy/base/postgres-podmonitor.yaml"
    "deploy/base/postgres-alerts.yaml"
    "deploy/base/kafka-source.yaml"
    "deploy/base/dlq-handler.yaml"
  )
  for f in "${never_present[@]}"; do
    if [[ -e "$dir/$f" ]]; then
      log_fail "  Redundant/old path still present: $f"
      ((errors++))
    fi
  done

  # ── Kustomization content checks ──
  # Verify overlays reference components correctly
  for overlay in dev staging prod; do
    local kust="$dir/deploy/overlays/$overlay/kustomization.yaml"
    if [[ ! -f "$kust" ]]; then
      continue
    fi

    if [[ "$f_postgres" == "true" ]]; then
      if ! grep -q "components/postgres" "$kust"; then
        log_fail "  $overlay/kustomization.yaml missing postgres component reference"
        ((errors++))
      fi
      if ! grep -q "postgres-cluster-patch" "$kust"; then
        log_fail "  $overlay/kustomization.yaml missing postgres-cluster-patch reference"
        ((errors++))
      fi
      if ! grep -q "postgres-backup-patch" "$kust"; then
        log_fail "  $overlay/kustomization.yaml missing postgres-backup-patch reference"
        ((errors++))
      fi
    fi

    if [[ "$es_kafka" == "true" ]]; then
      if ! grep -q "components/kafka" "$kust"; then
        log_fail "  $overlay/kustomization.yaml missing kafka component reference"
        ((errors++))
      fi
      if ! grep -q "kafka-source-patch" "$kust"; then
        log_fail "  $overlay/kustomization.yaml missing kafka-source-patch reference"
        ((errors++))
      fi
    fi

    # Dev overlay should have operator component when postgres is enabled
    if [[ "$overlay" == "dev" && "$f_postgres" == "true" ]]; then
      if ! grep -q "components/operator" "$kust"; then
        log_fail "  dev/kustomization.yaml missing operator component reference"
        ((errors++))
      fi
    fi

    # Staging/prod should NOT have operator component
    if [[ "$overlay" != "dev" ]]; then
      if grep -q "components/operator" "$kust" 2>/dev/null; then
        log_fail "  $overlay/kustomization.yaml should NOT reference operator component"
        ((errors++))
      fi
    fi
  done

  # ── Flux resource name checks ──
  for env in dev staging prod; do
    local flux_kust="$dir/deploy/flux/kustomization-${env}.yaml"
    if [[ -f "$flux_kust" ]]; then
      # Should use templated name, not hardcoded "rust-service"
      if grep -q "name: rust-service" "$flux_kust"; then
        log_fail "  deploy/flux/kustomization-${env}.yaml has hardcoded 'rust-service' name"
        ((errors++))
      fi
    fi
  done

  local flux_git="$dir/deploy/flux/git-repository.yaml"
  if [[ -f "$flux_git" ]]; then
    if grep -q "name: rust-service" "$flux_git"; then
      log_fail "  deploy/flux/git-repository.yaml has hardcoded 'rust-service' name"
      ((errors++))
    fi
  fi

  # ── Duplicate YAML key check in backup patches ──
  if [[ "$f_postgres" == "true" ]]; then
    for overlay in dev staging prod; do
      local patch="$dir/deploy/overlays/$overlay/postgres-backup-patch.yaml"
      if [[ -f "$patch" ]]; then
        local config_count
        config_count=$(grep -c "^  configuration:" "$patch" 2>/dev/null || true)
        # In a multi-document YAML, each ObjectStore doc should have exactly 1 configuration: key
        # Count within the ObjectStore section (after the --- separator)
        local obj_config
        obj_config=$(awk '/^---/{found=1} found{print}' "$patch" | grep -c "^  configuration:" 2>/dev/null || true)
        if [[ "$obj_config" -gt 1 ]]; then
          log_fail "  $overlay/postgres-backup-patch.yaml has duplicate 'configuration:' key"
          ((errors++))
        fi
      fi
    done
  fi

  # ── No deprecated patchesStrategicMerge ──
  for overlay in dev staging prod; do
    local kust="$dir/deploy/overlays/$overlay/kustomization.yaml"
    if [[ -f "$kust" ]] && grep -q "patchesStrategicMerge" "$kust"; then
      log_fail "  $overlay/kustomization.yaml uses deprecated patchesStrategicMerge"
      ((errors++))
    fi
  done

  return $errors
}

# Run kustomize build on overlays (validates YAML references)
validate_kustomize() {
  local dir="$1"
  local errors=0

  if ! command -v kustomize &>/dev/null; then
    log_skip "  kustomize not installed, skipping build validation"
    return 0
  fi

  # Note: kustomize build will fail for overlays that reference remote URLs
  # (like the operator component's CNPG release YAML) when offline.
  # We only validate overlays that DON'T pull remote resources, unless
  # the user has network access.

  for overlay in dev staging prod; do
    local overlay_dir="$dir/deploy/overlays/$overlay"
    if [[ ! -d "$overlay_dir" ]]; then
      continue
    fi

    # Dev with postgres will try to fetch remote CNPG operator YAML.
    # We test it but tolerate network failures.
    local output
    if output=$(kustomize build "$overlay_dir" 2>&1); then
      log_ok "  kustomize build overlays/$overlay"
    else
      # Check if it's a network error (remote resource fetch)
      if echo "$output" | grep -qiE "(dial tcp|no such host|timeout|connection refused|failed to get)"; then
        log_warn "  kustomize build overlays/$overlay (network error fetching remote resource -- OK offline)"
      else
        log_fail "  kustomize build overlays/$overlay"
        echo "$output" | head -20 | sed 's/^/         /'
        ((errors++))
      fi
    fi
  done

  return $errors
}

# Run Rust build checks
validate_rust() {
  local dir="$1"
  local errors=0

  if $QUICK; then
    log_skip "  Rust validation (--quick mode)"
    return 0
  fi

  # Clean post-generate hook artifacts
  (cd "$dir" && cargo clean 2>/dev/null) || true

  local step
  for step in "cargo fmt --all -- --check" "cargo clippy --all-targets --all-features -- -D warnings" "cargo build --all-features" "cargo test --all-features --no-run"; do
    local cmd_name
    cmd_name=$(echo "$step" | awk '{print $1, $2}')
    if (cd "$dir" && eval "$step" 2>&1) >/dev/null 2>&1; then
      log_ok "  $cmd_name"
    else
      log_fail "  $cmd_name"
      # Re-run to show output
      (cd "$dir" && eval "$step" 2>&1) | tail -30 | sed 's/^/         /'
      ((errors++))
      # Don't continue if build fails
      if [[ "$cmd_name" == "cargo build" ]]; then
        break
      fi
    fi
  done

  return $errors
}

# ── Run one scenario ───────────────────────────────────────────────────────
run_scenario() {
  local index="$1"
  local scenario="${SCENARIOS[$index]}"

  IFS='|' read -r label f_s3 f_kafka f_postgres es_kafka img_updates <<< "$scenario"

  log_header "Scenario $((index+1))/${#SCENARIOS[@]}: ${label}"
  log_info "s3=$f_s3  kafka=$f_kafka  postgres=$f_postgres  es_kafka=$es_kafka  img=$img_updates"

  local scenario_dir="$WORK_DIR/scenario-${label}"
  mkdir -p "$scenario_dir"

  local scenario_errors=0
  local gen_dir="$scenario_dir/test-app-${label}"

  # Step 1: Generate
  log_info "Generating template..."
  local gen_output
  if gen_output=$(generate_project "$label" "$f_s3" "$f_kafka" "$f_postgres" "$es_kafka" "$img_updates" "$scenario_dir" 2>&1); then
    log_ok "  cargo generate"
  else
    log_fail "  cargo generate"
    echo "$gen_output" | tail -20 | sed 's/^/         /'
    ((TOTAL++))
    ((FAILED++))
    FAILED_SCENARIOS+=("$label (generate failed)")
    return 1
  fi

  # Step 2: Structure validation
  log_info "Validating deploy structure..."
  if validate_structure "$gen_dir" "$f_s3" "$f_kafka" "$f_postgres" "$es_kafka" "$img_updates"; then
    log_ok "  Deploy structure OK"
  else
    scenario_errors=$?
  fi

  # Step 3: Kustomize validation
  log_info "Validating kustomize build..."
  if ! validate_kustomize "$gen_dir"; then
    ((scenario_errors+=$?))
  fi

  # Step 4: Rust validation
  log_info "Validating Rust build..."
  if ! validate_rust "$gen_dir"; then
    ((scenario_errors+=$?))
  fi

  # Result
  ((TOTAL++))
  if [[ $scenario_errors -eq 0 ]]; then
    ((PASSED++))
    log_ok "Scenario ${label}: PASSED"
  else
    ((FAILED++))
    FAILED_SCENARIOS+=("$label ($scenario_errors errors)")
    log_fail "Scenario ${label}: FAILED ($scenario_errors errors)"
  fi

  return $scenario_errors
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo -e "${BOLD}Template Matrix Validation${NC}"
  echo -e "${DIM}Testing all feature combinations of the cargo-generate template${NC}"
  echo ""

  check_prerequisites

  WORK_DIR=$(mktemp -d)
  log_info "Working directory: $WORK_DIR"
  if [[ "${KEEP_OUTPUT:-0}" == "1" ]]; then
    log_info "(will be preserved after run)"
  fi

  # Prepare a .git-free copy of the template source
  TEMPLATE_SOURCE_DIR=$(mktemp -d)
  prepare_template_source "$TEMPLATE_DIR" "$TEMPLATE_SOURCE_DIR"

  echo ""

  # Determine which scenarios to run
  local indices=()
  if [[ -n "$SINGLE_SCENARIO" ]]; then
    local idx=$((SINGLE_SCENARIO - 1))
    if [[ $idx -lt 0 || $idx -ge ${#SCENARIOS[@]} ]]; then
      log_fail "Invalid scenario number: $SINGLE_SCENARIO (valid: 1-${#SCENARIOS[@]})"
      exit 1
    fi
    indices+=("$idx")
  else
    for i in "${!SCENARIOS[@]}"; do
      indices+=("$i")
    done
  fi

  log_info "Running ${#indices[@]} scenario(s)$( $QUICK && echo ' (quick mode)' || echo '' )"
  echo ""

  # Run scenarios
  local any_failed=0
  if [[ $PARALLEL -gt 1 && ${#indices[@]} -gt 1 ]]; then
    # Parallel execution
    log_info "Parallel mode: up to $PARALLEL concurrent jobs"
    local pids=()
    local pid_labels=()
    local active=0

    for idx in "${indices[@]}"; do
      # Wait if at capacity
      while [[ $active -ge $PARALLEL ]]; do
        wait -n -p done_pid "${pids[@]}" 2>/dev/null || true
        ((active--))
      done

      run_scenario "$idx" &
      pids+=($!)
      IFS='|' read -r lbl _ _ _ _ _ <<< "${SCENARIOS[$idx]}"
      pid_labels+=("$lbl")
      ((active++))
    done

    # Wait for remaining
    for pid in "${pids[@]}"; do
      wait "$pid" || ((any_failed++))
    done
  else
    # Sequential execution
    for idx in "${indices[@]}"; do
      run_scenario "$idx" || ((any_failed++))
    done
  fi

  # ── Summary ──
  local elapsed=$(( $(date +%s) - START_TIME ))
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  RESULTS${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  Total:    $TOTAL"
  echo -e "  ${GREEN}Passed:   $PASSED${NC}"
  echo -e "  ${RED}Failed:   $FAILED${NC}"
  echo -e "  Time:     ${elapsed}s"

  if [[ ${#FAILED_SCENARIOS[@]} -gt 0 ]]; then
    echo ""
    echo -e "  ${RED}Failed scenarios:${NC}"
    for s in "${FAILED_SCENARIOS[@]}"; do
      echo -e "    - $s"
    done
  fi

  echo ""
  if [[ $FAILED -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All scenarios passed.${NC}"
  else
    echo -e "  ${RED}${BOLD}$FAILED scenario(s) failed.${NC}"
  fi

  if [[ "${KEEP_OUTPUT:-0}" == "1" ]]; then
    echo ""
    echo -e "  Output preserved at: $WORK_DIR"
  fi
  echo ""

  [[ $FAILED -eq 0 ]]
}

main "$@"
