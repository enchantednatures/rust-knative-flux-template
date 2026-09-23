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
#     plugin-method backup wiring, and backup credentials references
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
grep -q 'postgres-backup-storage' deploy/components/postgres/postgres-backup.yaml \
  && pass "backup credentials reference postgres-backup-storage" \
  || fail "backup credentials secret not referenced"
grep -q 'destinationPath.*-postgres-backups' deploy/components/postgres/postgres-backup.yaml \
  && pass "destinationPath points at <project>-postgres-backups bucket" \
  || fail "destinationPath bucket mismatch"

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

echo ""
if [ "$failures" -gt 0 ]; then
  echo "${RED}✗ VALIDATION FAILED: ${failures} check(s) failed${NC}"
  exit 1
fi
echo "${GREEN}✓ All PostgreSQL manifest checks passed${NC}"
