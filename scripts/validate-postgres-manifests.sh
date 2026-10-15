#!/usr/bin/env bash
set -euo pipefail

# Script: validate-postgres-manifests.sh
# Purpose: Validate the shipped CloudNativePG component manifests and the
#          application wiring (Cluster / ObjectStore / ScheduledBackup).
# Usage:   ./scripts/validate-postgres-manifests.sh
#
# Checks:
#   - PostgreSQL feature files exist (deploy/components/postgres/*)
#   - cargo-generate.toml ignore list covers the postgres paths
#   - kubectl kustomize renders the component cleanly
#   - Rendered/component output contains the expected CRs, TLS enforcement,
#     plugin-method backup wiring, and the provisioned-bucket claim contract
#   - Per-env / kind-local overlay renders carry the objectBuckets claim
#     wiring and the claim-name 63-char guard (generated projects only)
#   - base HelmRelease injects APP__POSTGRES__URL and mounts the CA volume
#   - per-env Flux Kustomizations depend on cnpg-operator and health-check
#     the Cluster
#
# The script runs inside a generated project (liquid fully rendered) or in
# the template repo against raw liquid — the YAML checks are liquid-tolerant.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

failures=0
pass() { echo "${GREEN}✓ $1${NC}"; }
fail() { echo "${RED}✗ $1${NC}"; failures=$((failures + 1)); }

# Repo root (script lives in scripts/)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Shared helpers for the object-bucket render assertions
# ---------------------------------------------------------------------------
# Project name (kebab-cased) derived from Cargo.toml when present; empty in the
# template repo, where the crate name is still liquid.
PROJECT_NAME=""
if [ -f Cargo.toml ]; then
  PROJECT_NAME="$(awk -F'"' '/^name = /{print $2; exit}' Cargo.toml 2>/dev/null || true)"
fi
PROJECT_NAME="${PROJECT_NAME//_/-}"

# Exact failure text required by the bucket-claim contract (do not reword); the
# offending claim name is appended so the operator can find it.
CLAIM_LEN_MSG="claim name exceeds 63 chars - the provisioner Secret reference would mismatch the truncated ObjectClaim name"

# check_claim_name <project> <suffix>: the provisioner names the Secret after
# the ObjectBucketClaim and both are capped at 63 DNS-label chars; a longer
# name lets the Secret and the (truncated) claim disagree.
check_claim_name() {
  local name="${1}-${2}"
  if [ "${#name}" -gt 63 ]; then
    fail "${CLAIM_LEN_MSG} (${name})"
    return 1
  fi
  return 0
}

# The overlays carry liquid only in the template repo; the render checks below
# run once cargo-generate has substituted it.
kustomize_is_liquid() { grep -q '{[%]' "$1"; }

# Pick a kustomize renderer once and reuse it consistently. Client-side only,
# no cluster access.
KUSTOMIZE_MODE=""
render_overlay() { # <dir> <outfile>  -> 0 on success
  local dir="$1" out="$2"
  if [ -z "$KUSTOMIZE_MODE" ]; then
    if kubectl kustomize "$dir" >"$out" 2>"$out.stderr"; then
      KUSTOMIZE_MODE="kubectl kustomize"
      return 0
    elif kustomize build "$dir" >"$out" 2>"$out.stderr"; then
      KUSTOMIZE_MODE="kustomize build"
      return 0
    fi
    return 1
  fi
  if [ "$KUSTOMIZE_MODE" = "kubectl kustomize" ]; then
    kubectl kustomize "$dir" >"$out" 2>"$out.stderr"
  else
    kustomize build "$dir" >"$out" 2>"$out.stderr"
  fi
}

# yq_assert <desc> <expected> <yq-expr> <file>
yq_assert() {
  local desc="$1" exp="$2" expr="$3" file="$4" got
  got="$(yq eval "$expr" "$file" 2>/dev/null | head -n1 || true)"
  if [ "$got" = "$exp" ]; then
    pass "$desc ($got)"
  else
    fail "$desc (expected '$exp', got '$got')"
  fi
}

# ---------------------------------------------------------------------------
# 1. Feature files exist
# ---------------------------------------------------------------------------
echo "==> Checking component files"
for f in \
  deploy/components/postgres/kustomization.yaml \
  deploy/components/postgres/postgres-cluster.yaml \
  deploy/components/postgres/postgres-backup.yaml; do
  if [ -f "$f" ]; then pass "$f"; else fail "$f (missing)"; fi
done

# ---------------------------------------------------------------------------
# 2. cargo-generate gating (template repo only; generated project omits it)
# ---------------------------------------------------------------------------
echo ""
echo "==> Checking cargo-generate gating"
if [ -f cargo-generate.toml ]; then
  if grep -q '"deploy/components/postgres"' cargo-generate.toml; then
    pass "feature_postgres ignore list covers deploy/components/postgres"
  else
    fail "deploy/components/postgres not in !feature_postgres ignore list"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Render the component with kustomize
# ---------------------------------------------------------------------------
echo ""
echo "==> Rendering deploy/components/postgres"
if ! kubectl kustomize deploy/components/postgres > /tmp/postgres-render.yaml 2>/tmp/postgres-render.err; then
  fail "kubectl kustomize deploy/components/postgres"
  echo "${YELLOW}--- stderr ---${NC}"
  cat /tmp/postgres-render.err || true
else
  pass "kubectl kustomize deploy/components/postgres"
  grep -q 'kind: Cluster' /tmp/postgres-render.yaml && pass "Cluster CR present" || fail "Cluster CR missing"
  grep -q 'kind: ObjectStore' /tmp/postgres-render.yaml && pass "ObjectStore CR present" || fail "ObjectStore CR missing"
  grep -q 'kind: ScheduledBackup' /tmp/postgres-render.yaml && pass "ScheduledBackup CR present" || fail "ScheduledBackup CR missing"
fi

# ---------------------------------------------------------------------------
# 4. Cluster + backup manifest contents
# ---------------------------------------------------------------------------
echo ""
echo "==> Checking Cluster contents"
grep -qF 'hostssl all all all scram-sha-256' deploy/components/postgres/postgres-cluster.yaml \
  && pass "TLS enforced server-side (hostssl pg_hba)" || fail "hostssl pg_hba rule missing"
grep -qF 'dataChecksums: true' deploy/components/postgres/postgres-cluster.yaml \
  && pass "dataChecksums enabled" || fail "dataChecksums missing"
grep -qF 'enableSuperuserAccess: false' deploy/components/postgres/postgres-cluster.yaml \
  && pass "superuser access disabled" || fail "enableSuperuserAccess not false"
grep -qF 'database: app' deploy/components/postgres/postgres-cluster.yaml \
  && pass "bootstrap database=app" || fail "bootstrap database is not app"
if grep -q 'plugins:' deploy/components/postgres/postgres-cluster.yaml; then
  pass "WAL archiver plugin attached to Cluster"
else
  fail "Cluster plugins (barman WAL archiver) missing"
fi

echo ""
echo "==> Checking PgBouncer pooler wiring"
if grep -q 'serverAltDNSNames' deploy/components/postgres/postgres-cluster.yaml \
   && grep -q 'postgres-rw-pooler' deploy/components/postgres/postgres-cluster.yaml; then
  pass "pooler service name registered in Cluster serverAltDNSNames"
else
  fail "serverAltDNSNames missing the pooler service (verify-full would fail)"
fi
if [ -f deploy/components/postgres-pooler/postgres-pooler.yaml ]; then
  kubectl kustomize deploy/components/postgres-pooler > /tmp/pooler-render.yaml \
    && pass "pooler component renders" || fail "pooler component kustomize fails"
  grep -q 'kind: Pooler' /tmp/pooler-render.yaml \
    && pass "Pooler CR present in rendered component" || fail "Pooler CR missing from render"
  grep -qF 'poolMode: transaction' deploy/components/postgres-pooler/postgres-pooler.yaml \
    && pass "pooler uses transaction pooling" || fail "poolMode is not transaction"
  grep -qF 'client_tls_sslmode: require' deploy/components/postgres-pooler/postgres-pooler.yaml \
    && pass "pooler forces client TLS" || fail "client_tls_sslmode not required"
  grep -q 'rw-pooler' deploy/base/helmrelease.yaml \
    && pass "APP__POSTGRES__HOST routes the DSN through the pooler" \
    || fail "APP__POSTGRES__HOST pooler wiring missing from helmrelease"
else
  pass "pooler disabled in this generation (postgres_pooler=false)"
fi

echo ""
echo "==> Checking backup wiring"
grep -q 'barmancloud.cnpg.io/v1' deploy/components/postgres/postgres-backup.yaml \
  && pass "ObjectStore apiVersion barmancloud.cnpg.io/v1" || fail "wrong ObjectStore apiVersion"
grep -qF 'method: plugin' deploy/components/postgres/postgres-backup.yaml \
  && pass "ScheduledBackup uses method: plugin" || fail "ScheduledBackup method is not plugin"
grep -q 'barman-cloud.cloudnative-pg.io' deploy/components/postgres/postgres-backup.yaml \
  && pass "plugin name barman-cloud.cloudnative-pg.io" || fail "plugin name missing"
grep -q 'AWS_ACCESS_KEY_ID' deploy/components/postgres/postgres-backup.yaml \
  && pass "backup credentials read the AWS_ACCESS_KEY_ID claim key" \
  || fail "backup credential key AWS_ACCESS_KEY_ID missing"
grep -q 'AWS_SECRET_ACCESS_KEY' deploy/components/postgres/postgres-backup.yaml \
  && pass "backup credentials read the AWS_SECRET_ACCESS_KEY claim key" \
  || fail "backup credential key AWS_SECRET_ACCESS_KEY missing"
grep -qE 'name:.*-postgres-backups"' deploy/components/postgres/postgres-backup.yaml \
  && pass "backup credentials reference the <project>-postgres-backups Secret" \
  || fail "backup credentials secret is not <project>-postgres-backups"
grep -q 'postgres-backup-storage' deploy/components/postgres/postgres-backup.yaml \
  && fail "stale postgres-backup-storage reference remains" \
  || pass "no stale postgres-backup-storage reference"
grep -q 'destinationPath.*-postgres-backups' deploy/components/postgres/postgres-backup.yaml \
  && pass "destinationPath points at <project>-postgres-backups bucket" \
  || fail "destinationPath bucket mismatch"

# ---------------------------------------------------------------------------
# 4b. Barman plugin install gating (content-based state detection)
#
# The barman plugin manifest URL in the cnpg-operator kustomization is the
# source of truth: when it is absent the plugin was skipped at generation
# time (barman_plugin_installed=false) and the backup manifests must still
# reference the plugin DNS name; when present both must be wired.
# NOTE: never grep the DNS name `barman-cloud.cloudnative-pg.io` against the
# kustomization — it also appears in postgres-backup.yaml, which must remain
# unchanged in both states.
# ---------------------------------------------------------------------------
KUSTOMIZATION="deploy/infrastructure/cnpg-operator/kustomization.yaml"
if [ -f "$KUSTOMIZATION" ]; then
  echo ""
  echo "==> Checking barman plugin install gating"
  # The char class below is deliberate: a literal open-brace-percent sequence
  # in this file aborts generation with "invalid syntax" (Tera parses it on
  # every generate), so the pattern must never spell one out.
  if grep -q '{[%]' "$KUSTOMIZATION"; then
    pass "cnpg-operator kustomization still contains liquid (template repo; render check skipped)"
  elif ! kubectl kustomize deploy/infrastructure/cnpg-operator > /tmp/cnpg-operator-render.yaml 2>/tmp/cnpg-operator-render.err; then
    fail "kubectl kustomize deploy/infrastructure/cnpg-operator"
    echo "${YELLOW}--- stderr ---${NC}"
    cat /tmp/cnpg-operator-render.err || true
  else
    pass "kubectl kustomize deploy/infrastructure/cnpg-operator"
  fi
  if grep -q 'plugin-barman-cloud/releases' "$KUSTOMIZATION"; then
    pass "barman plugin manifest URL present in cnpg-operator kustomization"
  else
    pass "barman plugin skipped in this generation (barman_plugin_installed=false)"
    if ! grep -q 'plugin-barman-cloud' "$KUSTOMIZATION"; then
      pass "no barman plugin residue in cnpg-operator kustomization"
    else
      fail "barman plugin residue in cnpg-operator kustomization despite skip"
    fi
    grep -q 'barman-cloud.cloudnative-pg.io' deploy/components/postgres/postgres-backup.yaml \
      && pass "backup manifests still reference plugin name barman-cloud.cloudnative-pg.io" \
      || fail "plugin name missing from postgres-backup.yaml after skip"
  fi
fi

# ---------------------------------------------------------------------------
# 4c. ObjectBucketClaim name length guard
#
# The provisioner names the Secret after the ObjectBucketClaim and truncates the
# claim at 63 chars, so an oversized name makes the manifests point at a Secret
# the provisioner never creates.
# ---------------------------------------------------------------------------
if [ -n "$PROJECT_NAME" ]; then
  echo ""
  echo "==> Checking ObjectBucketClaim name lengths"
  if [ -d deploy/components/postgres ]; then
    if check_claim_name "$PROJECT_NAME" "postgres-backups"; then
      pass "claim ${PROJECT_NAME}-postgres-backups within 63 chars"
    fi
  fi
  if grep -q 'app-data' deploy/base/helmrelease.yaml 2>/dev/null; then
    if check_claim_name "$PROJECT_NAME" "app-data"; then
      pass "claim ${PROJECT_NAME}-app-data within 63 chars"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 5. App wiring (HelmRelease env + CA volume)
# ---------------------------------------------------------------------------
echo ""
echo "==> Checking application wiring"
grep -q 'APP__POSTGRES__URL' deploy/base/helmrelease.yaml \
  && pass "APP__POSTGRES__URL injected via secretKeyRef" || fail "APP__POSTGRES__URL env missing"
grep -q 'postgres-app' deploy/base/helmrelease.yaml \
  && pass "reads <cluster>-app secret key uri" || fail "-postgres-app secret reference missing"
grep -q 'postgres-ca' deploy/base/helmrelease.yaml \
  && pass "CA cert volume mounted into the pod" || fail "postgres-ca volume missing"

echo ""
echo "==> Checking base app-data claim env contract"
if grep -q 'app-data' deploy/base/helmrelease.yaml 2>/dev/null; then
  grep -q 'secretKeyRef' deploy/base/helmrelease.yaml \
    && pass "base env reads app-data credentials via secretKeyRef" \
    || fail "base env app-data secretKeyRef missing"
  grep -q 'AWS_ACCESS_KEY_ID' deploy/base/helmrelease.yaml \
    && pass "base env pulls AWS_ACCESS_KEY_ID from the claim Secret" \
    || fail "base env AWS_ACCESS_KEY_ID missing"
  grep -q 'AWS_SECRET_ACCESS_KEY' deploy/base/helmrelease.yaml \
    && pass "base env pulls AWS_SECRET_ACCESS_KEY from the claim Secret" \
    || fail "base env AWS_SECRET_ACCESS_KEY missing"
  grep -qE 'configMapKeyRef' deploy/base/helmrelease.yaml \
    && pass "base env reads bucket identity via configMapKeyRef" \
    || fail "base env app-data configMapKeyRef missing"
  grep -qF 'http://$(BUCKET_HOST):$(BUCKET_PORT)' deploy/base/helmrelease.yaml \
    && pass "base env interpolates APP__S3__ENDPOINT from the claim ConfigMap" \
    || fail "base env BUCKET_HOST/BUCKET_PORT interpolation missing"
else
  pass "base env app-data claim contract not present (feature_s3=false)"
fi

# Per-env Flux Kustomizations: dependsOn + healthChecks
for env in dev staging prod; do
  kf="deploy/flux/kustomization-${env}.yaml"
  if [ -f "$kf" ]; then
    grep -q 'name: cnpg-operator' "$kf" \
      && pass "$kf depends on cnpg-operator" || fail "$kf missing cnpg-operator dependsOn"
    grep -q 'kind: Cluster' "$kf" \
      && pass "$kf healthChecks the CNPG Cluster" || fail "$kf missing Cluster healthCheck"
  else
    fail "$kf (missing)"
  fi
done

# ---------------------------------------------------------------------------
# 6. Per-env overlay render assertions (generated projects only)
#
# The overlays carry liquid in the template repo; these checks run once
# cargo-generate has substituted it. Rendering is client-side (no cluster).
# Expected storageClass/endpoint are read from the rendered overlay so custom
# per-env values validate as well as the ceph defaults.
# ---------------------------------------------------------------------------
echo ""
echo "==> Checking per-env overlay object-bucket wiring"
for env in dev staging prod; do
  overlay="deploy/overlays/${env}/kustomization.yaml"
  if [ ! -f "$overlay" ]; then
    fail "$overlay (missing)"
    continue
  fi
  if kustomize_is_liquid "$overlay"; then
    pass "overlays/${env}: liquid template (render check skipped)"
    continue
  fi
  render="${TMPDIR:-/tmp}/validate-overlay-${env}.yaml"
  if ! render_overlay "deploy/overlays/${env}" "$render"; then
    fail "render deploy/overlays/${env}"
    cat "${render}.stderr" || true
    continue
  fi
  pass "render deploy/overlays/${env} (${KUSTOMIZE_MODE})"

  case "$env" in
    staging) suffix="-staging" ;;
    prod)    suffix="-prod" ;;
    *)       suffix="" ;;
  esac

  exp_sc="$(grep -m1 -oE 'storageClassName:[[:space:]]*"[^"]*"' "$overlay" | sed -E 's/.*"([^"]*)".*/\1/' || true)"
  exp_ep="$(grep -m1 -oE 'endpointURL:[[:space:]]*"[^"]*"' "$overlay" | sed -E 's/.*"([^"]*)".*/\1/' || true)"

  if yq eval 'select(.kind == "HelmRelease") | .spec.values.objectBuckets."postgres-backups"' "$render" 2>/dev/null | grep -qv 'null'; then
    yq_assert "overlays/${env}: objectBuckets.postgres-backups.bucketName" \
      "${PROJECT_NAME}-postgres-backups${suffix}" \
      'select(.kind == "HelmRelease") | .spec.values.objectBuckets."postgres-backups".bucketName' "$render"
    yq_assert "overlays/${env}: objectBuckets.postgres-backups.endpointURL" \
      "$exp_ep" \
      'select(.kind == "HelmRelease") | .spec.values.objectBuckets."postgres-backups".endpointURL' "$render"
    yq_assert "overlays/${env}: objectBuckets.postgres-backups.storageClassName" \
      "$exp_sc" \
      'select(.kind == "HelmRelease") | .spec.values.objectBuckets."postgres-backups".storageClassName' "$render"
    yq_assert "overlays/${env}: ObjectStore endpointURL" \
      "$exp_ep" \
      'select(.kind == "ObjectStore") | .spec.configuration.endpointURL' "$render"
    yq_assert "overlays/${env}: ObjectStore destinationPath" \
      "s3://${PROJECT_NAME}-postgres-backups${suffix}/" \
      'select(.kind == "ObjectStore") | .spec.configuration.destinationPath' "$render"
  fi

  if yq eval 'select(.kind == "HelmRelease") | .spec.values.objectBuckets."app-data"' "$render" 2>/dev/null | grep -qv 'null'; then
    yq_assert "overlays/${env}: objectBuckets.app-data.bucketName" \
      "${PROJECT_NAME}-app-data${suffix}" \
      'select(.kind == "HelmRelease") | .spec.values.objectBuckets."app-data".bucketName' "$render"
  fi

  if [ "$env" != "dev" ]; then
    grep -q 's3-config' "$render" \
      && fail "overlays/${env}: legacy s3-config present in render" \
      || pass "overlays/${env}: no s3-config in render"
  fi
done

# ---------------------------------------------------------------------------
# 7. Kind-local app-overlay render assertions (generated projects only)
# ---------------------------------------------------------------------------
echo ""
echo "==> Checking kind-local app-overlay (deploy/dev/app-overlay)"
APP_OVERLAY="deploy/dev/app-overlay/kustomization.yaml"
if [ ! -f "$APP_OVERLAY" ]; then
  fail "$APP_OVERLAY (missing)"
elif kustomize_is_liquid "$APP_OVERLAY"; then
  pass "app-overlay: liquid template (render check skipped)"
else
  render="${TMPDIR:-/tmp}/validate-app-overlay.yaml"
  if ! render_overlay "deploy/dev/app-overlay" "$render"; then
    fail "render deploy/dev/app-overlay"
    cat "${render}.stderr" || true
  else
    pass "render deploy/dev/app-overlay (${KUSTOMIZE_MODE})"
    buckets="$(yq eval 'select(.kind == "HelmRelease") | .spec.values.objectBuckets' "$render" 2>/dev/null | head -n1 || true)"
    if [ -z "$buckets" ] || [ "$buckets" = "null" ]; then
      pass "app-overlay: HelmRelease objectBuckets removed"
    else
      fail "app-overlay: HelmRelease objectBuckets still present"
    fi
    if [ -d deploy/components/postgres ]; then
      yq_assert "app-overlay: ObjectStore endpointURL falls back to RustFS" \
        "http://rustfs.rustfs.svc.cluster.local:9000" \
        'select(.kind == "ObjectStore") | .spec.configuration.endpointURL' "$render"
    fi
  fi
fi

echo ""
if [ "$failures" -gt 0 ]; then
  echo "${RED}✗ VALIDATION FAILED: ${failures} check(s) failed${NC}"
  exit 1
fi
echo "${GREEN}✓ All PostgreSQL manifest checks passed${NC}"
