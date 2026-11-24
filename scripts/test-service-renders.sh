#!/usr/bin/env bash
#
# test-service-renders.sh - render matrix for the thin service sub-template.
#
# Generates a platform project plus services from the LOCAL service-template
# (no cluster, no network beyond the pinned ksvc chart pull), renders each
# service's overlays with `kubectl kustomize` (default load restrictor) and the
# chart-owned resources with `helm template --kube-version 1.32.0`, then asserts
# the workload, infrastructure-reuse and limitation contracts from Todo 14/22.
#
# Usage:
#   bash scripts/test-service-renders.sh
#
# Environment:
#   TEMPLATE_PATH     Local service-template directory (default: <repo>/service-template)
#   PLATFORM_TEMPLATE Platform template root (default: <repo>)
#   WORKDIR           Fixture directory (default: mktemp under /tmp)
#   KEEP_WORKDIR=1    Keep the fixture directory after the run
#
# Requires: bash, cargo-generate >= 0.23, helm, kubectl (kustomize), yq v4,
# python3 with PyYAML. No Kubernetes cluster is contacted.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname -- "$SCRIPT_DIR")"
TEMPLATE_PATH="${TEMPLATE_PATH:-$ROOT/service-template}"
PLATFORM_TEMPLATE="${PLATFORM_TEMPLATE:-$ROOT}"
KEEP_WORKDIR="${KEEP_WORKDIR:-0}"

if [[ -z "${WORKDIR:-}" ]]; then
	WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/service-renders.XXXXXX")"
fi
mkdir -p "$WORKDIR"

cleanup() {
	if [[ "$KEEP_WORKDIR" != "1" ]]; then
		rm -rf "$WORKDIR"
	fi
}
trap cleanup EXIT

PASS=0
FAIL=0
VARIANTS=0

pass() { printf 'PASS %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ── Preconditions ─────────────────────────────────────────────────────────
have cargo || die "cargo is required"
have helm || die "helm is required"
have kubectl || die "kubectl is required"
have python3 || die "python3 is required"
have yq || die "yq (mikefarah v4) is required"
have tar || die "tar is required"
cargo generate --version >/dev/null 2>&1 || die "cargo-generate >= 0.23 is required"
python3 -c 'import yaml' >/dev/null 2>&1 || die "python3 PyYAML is required"
[[ -f "$TEMPLATE_PATH/cargo-generate.toml" ]] || die "service-template not found at $TEMPLATE_PATH"
[[ -f "$PLATFORM_TEMPLATE/cargo-generate.toml" ]] || die "platform template not found at $PLATFORM_TEMPLATE"

IMAGE_REGISTRY="ghcr.io"
GITHUB_ORG="enchantednatures"
KAFKA_DEV="kafka.kafka-dev.svc.cluster.local:9092"
KAFKA_STAGING="kafka.staging.svc.cluster.local:9093"
KAFKA_PROD="kafka.prod.svc.cluster.local:9094"
PROM_DEV="http://prometheus.dev.svc.cluster.local:9090"
PROM_STAGING="http://prometheus.staging.svc.cluster.local:9090"
PROM_PROD="http://prometheus.prod.svc.cluster.local:9090"

mkdir -p "$WORKDIR/values" "$WORKDIR/platform" "$WORKDIR/renders"

# ── Fixture writers ───────────────────────────────────────────────────────

# write_platform_values <file> <project> <kafka> <flagger>
write_platform_values() {
	local file="$1" project="$2" kafka="$3" flagger="$4"
	cat >"$file" <<EOF
[values]
project_name = "$project"
project_author = "CI Bot <ci@github.com>"
template_repo_url = "https://example.com/example/service-template.git"
template_ref = "main"
feature_s3 = true
feature_postgres = true
feature_kafka = $kafka
feature_flagger = $flagger
feature_gha_runner = false
event_source_kafka = $kafka
enable_image_updates = false
target_namespace = "default"
github_org = "$GITHUB_ORG"
github_repo = "rust-knative-flux-template"
default_branch = "main"
image_registry = "$IMAGE_REGISTRY"
git_auth_secret = ""
image_pull_secret = ""
custom_domain = ""
network_policy_allow_all = false
use_default_scaling = false
base_min_scale = "1"
base_max_scale = "10"
base_target = "100"
base_cpu_request = "100m"
base_cpu_limit = "500m"
base_memory_request = "64Mi"
base_memory_limit = "256Mi"
dev_min_scale = "0"
dev_max_scale = "3"
dev_cpu_request = "100m"
dev_cpu_limit = "500m"
dev_memory_request = "64Mi"
dev_memory_limit = "256Mi"
staging_min_scale = "1"
staging_max_scale = "5"
staging_cpu_request = "200m"
staging_cpu_limit = "800m"
staging_memory_request = "128Mi"
staging_memory_limit = "384Mi"
prod_min_scale = "2"
prod_max_scale = "20"
prod_cpu_request = "250m"
prod_cpu_limit = "1000m"
prod_memory_request = "256Mi"
prod_memory_limit = "512Mi"
postgres_version = "18"
postgres_pooler = true
postgres_pooler_instances_dev = "1"
postgres_pooler_instances_staging = "2"
postgres_pooler_instances_prod = "4"
postgres_instances_dev = "1"
postgres_instances_staging = "2"
postgres_instances_prod = "3"
postgres_storage_class = "standard"
backup_schedule = "0 2 * * *"
backup_retention_dev = "7"
backup_retention_staging = "14"
backup_retention_prod = "30"
barman_plugin_installed = false
ceph_rgw_endpoint_dev = "http://rook-ceph-rgw-ceph-objectstore.rook-ceph.svc:80"
ceph_rgw_endpoint_staging = "https://rook-ceph-rgw-ceph-objectstore.rook-ceph.svc:443"
ceph_rgw_endpoint_prod = "https://rook-ceph-rgw-ceph-objectstore.rook-ceph.svc:443"
ceph_bucket_storage_class = "ceph-bucket"
kafka_broker_url = "$KAFKA_DEV"
kafka_topic = "events"
kafka_event_name = "com.example.service.event.published"
canary_success_rate_threshold = "99"
canary_latency_threshold_ms = "500"
flagger_prometheus_url_staging = "$PROM_STAGING"
flagger_prometheus_url_prod = "$PROM_PROD"
flagger_operator_metrics_server = "$PROM_DEV"
EOF
}

# write_service_values <file> (reads V_* globals set by v()/run_variant)
write_service_values() {
	local file="$1"
	cat >"$file" <<EOF
[values]
service_slug = "$V_SVC_SLUG"
db_name = "$V_DB"
project_slug = "$V_PROJECT"
image_registry = "$IMAGE_REGISTRY"
github_org = "$GITHUB_ORG"
include_postgres = $V_PG_BOOL
include_s3 = $V_S3_BOOL
kafka_publish = $V_PUB_BOOL
kafka_source = $V_SRC_BOOL
workload_deployment = $V_DEPLOY_BOOL
enable_flagger = $V_FLAGGER_BOOL
enable_image_updates = $V_IMG_BOOL
target_namespace_dev = "$V_PROJECT-dev"
target_namespace_staging = "$V_PROJECT-staging"
target_namespace_prod = "$V_PROJECT-prod"
pg_cluster = "$V_PROJECT-postgres"
pg_app_secret = "$V_PROJECT-postgres-app"
pg_ca_secret = "$V_PROJECT-postgres-ca"
pg_pooler_host = "$V_PROJECT-postgres-rw-pooler"
redis_url = "redis://redis.$V_PROJECT-dev.svc.cluster.local:6379"
otel_endpoint = "http://otel-collector.observability.svc.cluster.local:4317"
kafka_bootstrap_servers = "$KAFKA_DEV"
kafka_bootstrap_servers_staging = "$KAFKA_STAGING"
kafka_bootstrap_servers_prod = "$KAFKA_PROD"
kafka_topic = "$SVC_NAME-events"
kafka_consumer_group = "$SVC_NAME-consumers"
canary_prometheus_url_dev = "$PROM_DEV"
canary_prometheus_url_staging = "$PROM_STAGING"
canary_prometheus_url_prod = "$PROM_PROD"
EOF
}

bool() { if [[ "$1" == "1" ]]; then printf 'true'; else printf 'false'; fi; }

# append_workspace_member <Cargo.toml> <member>
append_workspace_member() {
	python3 - "$1" "$2" <<'PY'
import re
import sys

path, member = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
match = re.search(r"(members\s*=\s*\[)([^\]]*)(\])", text, re.S)
if not match:
    sys.exit(f"no [workspace] members array in {path}")
inner = match.group(2)
existing = re.findall(r'"([^"]+)"', inner)
if member in existing:
    sys.exit(0)
if inner.strip():
    new_inner = inner.rstrip()
    if not new_inner.endswith(","):
        new_inner += ","
    new_inner += f'\n    "{member}",\n'
else:
    new_inner = f'\n    "{member}",\n'
text = text[:match.start(2)] + new_inner + text[match.end(2):]
open(path, "w", encoding="utf-8").write(text)
PY
}

# ── Generation ────────────────────────────────────────────────────────────

# prepare_platform_template <source-dir>
#
# The platform template root also contains this test harness. Rendering the
# platform straight from the worktree would make cargo-generate parse (and
# reject) the harness' own guard strings, and would copy a test-only script into
# the generated fixture. Snapshot the template into /tmp and drop only the
# harness; the service-template itself is still rendered from TEMPLATE_PATH.
prepare_platform_template() {
	local source="$1"
	local dest="$WORKDIR/platform-template"
	rm -rf "$dest"
	mkdir -p "$dest"
	if command -v git >/dev/null 2>&1 && git -C "$source" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		git -C "$source" archive HEAD | tar -x -C "$dest"
	else
		tar -C "$source" \
			--exclude='./.git' \
			--exclude='./target' \
			--exclude='./scripts/test-service-renders.sh' \
			-cf - . | tar -x -C "$dest"
	fi
	rm -f "$dest/scripts/test-service-renders.sh"
	printf '%s\n' "$dest"
}

gen_platform() {
	local name="$1" values="$2" dest="$3"
	local log="$WORKDIR/generate-platform-$name.log"
	rm -rf "$dest"
	mkdir -p "$dest"
	if ! cargo generate --path "$PLATFORM_TEMPLATE" --name "$name" --init \
		--template-values-file "$values" --destination "$dest" --silent \
		>"$log" 2>&1; then
		tail -40 "$log" >&2
		die "platform generation failed for $name"
	fi
}

gen_service() {
	local platform="$1" dir_name="$2" svc_slug="$3" values="$4"
	local dest="$platform/services/$dir_name"
	local log="$WORKDIR/generate-service-$dir_name.log"
	rm -rf "$dest"
	mkdir -p "$dest"
	if ! cargo generate --path "$TEMPLATE_PATH" --name "$svc_slug" --init \
		--template-values-file "$values" --destination "$dest" --silent \
		>"$log" 2>&1; then
		tail -40 "$log" >&2
		die "service generation failed for $dir_name"
	fi
	append_workspace_member "$platform/Cargo.toml" "services/$dir_name"
}

# ── Rendering ─────────────────────────────────────────────────────────────

render_variant() {
	local platform="$1" svc_dir="$2" render_dir="$3"
	local env ns
	for env in dev staging prod; do
		mkdir -p "$render_dir/$env"
		if ! kubectl kustomize "$platform/services/$svc_dir/deploy/overlays/$env" \
			>"$render_dir/$env/overlay.yaml" 2>"$render_dir/$env/kustomize.err"; then
			fail "$V_NAME/$env kustomize render"
			return 1
		fi
		ns="$(yq -r 'select(.kind == "HelmRelease") | .metadata.namespace' "$render_dir/$env/overlay.yaml")"
		if [[ -z "$ns" || "$ns" == "null" ]]; then
			fail "$V_NAME/$env overlay namespace"
			return 1
		fi
		yq 'select(.kind == "HelmRelease") | .spec.values' "$render_dir/$env/overlay.yaml" >"$render_dir/$env/values.yaml"
		if ! helm template "$SVC_NAME" "$CHART_DIR" -f "$render_dir/$env/values.yaml" \
			--namespace "$ns" --kube-version 1.32.0 \
			>"$render_dir/$env/chart.yaml" 2>"$render_dir/$env/helm.err"; then
			fail "$V_NAME/$env helm render"
			return 1
		fi
	done
	if [[ -d "$platform/services/$svc_dir/deploy/flux" ]]; then
		if ! kubectl kustomize "$platform/services/$svc_dir/deploy/flux" \
			>"$render_dir/flux.yaml" 2>"$render_dir/flux.err"; then
			fail "$V_NAME flux kustomize render"
			return 1
		fi
	fi
	return 0
}

# ── Verifier ──────────────────────────────────────────────────────────────

write_verifier() {
	cat >"$WORKDIR/verify.py" <<'PY'
#!/usr/bin/env python3
"""Structural assertions for one service render variant (Task 22)."""

import argparse
import os
import sys

import yaml

LIQUID_OPEN = "{" + "{"
LIQUID_TAG = "{" + "%"

ENVS = ("dev", "staging", "prod")
# service-template overlay defaults (deploy/overlays/*/kustomization.yaml).
SCALE = {"dev": (0, 3), "staging": (1, 5), "prod": (2, 20)}
REPLICAS = {"dev": 1, "staging": 2, "prod": 3}


def load_docs(path):
    with open(path, encoding="utf-8") as handle:
        return [doc for doc in yaml.safe_load_all(handle) if isinstance(doc, dict) and doc]


def kind_of(doc):
    return doc.get("kind")


def name_of(doc):
    return (doc.get("metadata") or {}).get("name")


def api_of(doc):
    return doc.get("apiVersion", "")


def env_map(container):
    result = {}
    for entry in container.get("env") or []:
        if isinstance(entry, dict) and "name" in entry:
            result[entry["name"]] = entry
    return result


def secret_ref(entry):
    return ((entry or {}).get("valueFrom") or {}).get("secretKeyRef") or {}


def configmap_ref(entry):
    return ((entry or {}).get("valueFrom") or {}).get("configMapKeyRef") or {}


def nonzero(value):
    if value is None:
        return False
    if isinstance(value, str):
        return value.strip() not in ("", "0", "0%")
    return value != 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True)
    parser.add_argument("--kind", choices=("knative", "deployment"), required=True)
    parser.add_argument("--svc", required=True)
    parser.add_argument("--svc-slug", required=True)
    parser.add_argument("--svc-dir", required=True)
    parser.add_argument("--render-dir", required=True)
    parser.add_argument("--base-hr", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--registry", required=True)
    parser.add_argument("--org", required=True)
    parser.add_argument("--db-name", required=True)
    parser.add_argument("--postgres", type=int, default=0)
    parser.add_argument("--s3", type=int, default=0)
    parser.add_argument("--kafka-publish", type=int, default=0)
    parser.add_argument("--kafka-source", type=int, default=0)
    parser.add_argument("--flagger", type=int, default=0)
    parser.add_argument("--image-updates", type=int, default=0)
    parser.add_argument("--pdb", choices=("on", "off"), default="on")
    parser.add_argument("--ns-dev", required=True)
    parser.add_argument("--ns-staging", required=True)
    parser.add_argument("--ns-prod", required=True)
    parser.add_argument("--kafka-dev", required=True)
    parser.add_argument("--kafka-staging", required=True)
    parser.add_argument("--kafka-prod", required=True)
    parser.add_argument("--prom-dev", required=True)
    parser.add_argument("--prom-staging", required=True)
    parser.add_argument("--prom-prod", required=True)
    args = parser.parse_args()

    effective_source = bool(args.kafka_source) and args.kind == "knative"
    effective_flagger = bool(args.flagger) and args.kind == "knative"

    namespaces = {"dev": args.ns_dev, "staging": args.ns_staging, "prod": args.ns_prod}
    kafka = {"dev": args.kafka_dev, "staging": args.kafka_staging, "prod": args.kafka_prod}
    prom = {"dev": args.prom_dev, "staging": args.prom_staging, "prod": args.prom_prod}
    failures = 0

    def check(label, condition, detail=""):
        nonlocal failures
        if condition:
            print(f"PASS {label}")
        else:
            print(f"FAIL {label}" + (f": {detail}" if detail else ""))
            failures += 1

    base_text = open(args.base_hr, encoding="utf-8").read()

    for env in ENVS:
        prefix = f"{args.name}/{env}"
        overlay_path = os.path.join(args.render_dir, env, "overlay.yaml")
        chart_path = os.path.join(args.render_dir, env, "chart.yaml")
        try:
            overlay = load_docs(overlay_path)
            check(f"{prefix} overlay YAML parses", True)
        except Exception as exc:  # noqa: BLE001 - report the parse failure
            check(f"{prefix} overlay YAML parses", False, repr(exc))
            continue
        try:
            chart = load_docs(chart_path)
            check(f"{prefix} chart YAML parses", True)
        except Exception as exc:  # noqa: BLE001
            check(f"{prefix} chart YAML parses", False, repr(exc))
            continue

        chart_text = open(chart_path, encoding="utf-8").read()

        releases = [doc for doc in overlay if kind_of(doc) == "HelmRelease"]
        check(f"{prefix} HelmRelease present", len(releases) == 1, f"count={len(releases)}")
        if not releases:
            continue
        release = releases[0]
        values = release.get("spec", {}).get("values", {}) or {}
        app = (values.get("services") or {}).get("app") or {}
        env_entries = app.get("env") or []
        envs = env_map({"env": env_entries})

        check(f"{prefix} HelmRelease name", name_of(release) == args.svc, name_of(release))
        check(
            f"{prefix} HelmRelease namespace",
            (release.get("metadata") or {}).get("namespace") == namespaces[env],
            (release.get("metadata") or {}).get("namespace"),
        )
        check(f"{prefix} env names unique", len(env_entries) == len(envs), f"{len(env_entries)} vs {len(envs)}")
        check(f"{prefix} no objectBuckets value", "objectBuckets" not in values)
        check(f"{prefix} base HelmRelease has no objectBuckets", "objectBuckets" not in base_text)

        workload = None
        kafka_sources = [doc for doc in chart if kind_of(doc) == "KafkaSource"]
        canaries = [doc for doc in chart if kind_of(doc) == "Canary"]
        if args.kind == "knative":
            services = [
                doc
                for doc in chart
                if kind_of(doc) == "Service" and api_of(doc).startswith("serving.knative.dev/")
            ]
            app_services = [doc for doc in services if name_of(doc) == args.svc]
            expected_services = 2 if effective_source else 1
            check(
                f"{prefix} Knative Service count",
                len(services) == expected_services,
                f"expected={expected_services} count={len(services)}",
            )
            check(f"{prefix} Knative Service present", len(app_services) == 1, f"count={len(app_services)}")
            check(f"{prefix} no Deployment", not any(kind_of(doc) == "Deployment" for doc in chart))
            check(f"{prefix} no core v1 Service", not any(kind_of(doc) == "Service" and api_of(doc) == "v1" for doc in chart))
            check(f"{prefix} no HorizontalPodAutoscaler", not any(kind_of(doc) == "HorizontalPodAutoscaler" for doc in chart))

            expected_sources = 1 if effective_source else 0
            check(
                f"{prefix} KafkaSource count",
                len(kafka_sources) == expected_sources,
                f"expected={expected_sources} count={len(kafka_sources)}",
            )
            expected_canaries = 1 if effective_flagger else 0
            check(
                f"{prefix} Canary count",
                len(canaries) == expected_canaries,
                f"expected={expected_canaries} count={len(canaries)}",
            )

            if app_services:
                workload = app_services[0]
                check(f"{prefix} Knative Service name", name_of(workload) == args.svc, name_of(workload))
                annotations = (
                    ((workload.get("spec") or {}).get("template") or {}).get("metadata") or {}
                ).get("annotations") or {}
                expected_min, expected_max = SCALE[env]
                check(
                    f"{prefix} scaling min-scale",
                    annotations.get("autoscaling.knative.dev/min-scale") == str(expected_min),
                    annotations.get("autoscaling.knative.dev/min-scale"),
                )
                check(
                    f"{prefix} scaling max-scale",
                    annotations.get("autoscaling.knative.dev/max-scale") == str(expected_max),
                    annotations.get("autoscaling.knative.dev/max-scale"),
                )
                pod_spec = ((workload.get("spec") or {}).get("template") or {}).get("spec") or {}
                check(f"{prefix} containerConcurrency", pod_spec.get("containerConcurrency") == 100, pod_spec.get("containerConcurrency"))
                check(f"{prefix} timeoutSeconds", pod_spec.get("timeoutSeconds") == 300, pod_spec.get("timeoutSeconds"))

            if effective_flagger:
                check(f"{prefix} canary targets Knative Service", bool(canaries) and name_of(canaries[0]) == args.svc)
                address = (((app.get("flagger") or {}).get("metrics") or {}).get("prometheusAddress"))
                check(f"{prefix} flagger prometheusAddress", address == prom[env], address)
                if env != "dev":
                    check(f"{prefix} flagger prometheusAddress not dev default", address != prom["dev"], address)
        else:
            deployments = [doc for doc in chart if kind_of(doc) == "Deployment" and api_of(doc) == "apps/v1"]
            check(f"{prefix} Deployment present", len(deployments) == 1, f"count={len(deployments)}")
            check(
                f"{prefix} no Knative Service",
                not any(api_of(doc).startswith("serving.knative.dev/") for doc in chart),
            )
            check(f"{prefix} no autoscaling.knative.dev", "autoscaling.knative.dev" not in chart_text)
            check(f"{prefix} no HorizontalPodAutoscaler", not any(kind_of(doc) == "HorizontalPodAutoscaler" for doc in chart))
            check(f"{prefix} no Canary", not any(kind_of(doc) == "Canary" for doc in chart))
            check(f"{prefix} no KafkaSource", not any(kind_of(doc) == "KafkaSource" for doc in chart))

            core_services = [doc for doc in chart if kind_of(doc) == "Service" and api_of(doc) == "v1"]
            check(f"{prefix} core Service present", len(core_services) == 1, f"count={len(core_services)}")
            if core_services:
                check(f"{prefix} core Service name", name_of(core_services[0]) == args.svc, name_of(core_services[0]))
                ports = ((core_services[0].get("spec") or {}).get("ports") or [{}])[0]
                check(f"{prefix} core Service port 80", ports.get("port") == 80, ports.get("port"))
                check(f"{prefix} core Service targetPort 8080", ports.get("targetPort") == 8080, ports.get("targetPort"))

            pdbs = [doc for doc in chart if kind_of(doc) == "PodDisruptionBudget"]
            if args.pdb == "on":
                check(f"{prefix} PodDisruptionBudget present", len(pdbs) == 1, f"count={len(pdbs)}")
                if pdbs:
                    spec = pdbs[0].get("spec") or {}
                    active = [key for key in ("minAvailable", "maxUnavailable") if nonzero(spec.get(key))]
                    check(
                        f"{prefix} PDB exactly one non-zero field",
                        len(active) == 1,
                        f"active={active} spec={spec}",
                    )
            else:
                check(f"{prefix} no PodDisruptionBudget", len(pdbs) == 0, f"count={len(pdbs)}")

            if deployments:
                workload = deployments[0]
                check(f"{prefix} Deployment name", name_of(workload) == args.svc, name_of(workload))
                check(f"{prefix} replicas", (workload.get("spec") or {}).get("replicas") == REPLICAS[env], (workload.get("spec") or {}).get("replicas"))
                annotations = (
                    ((workload.get("spec") or {}).get("template") or {}).get("metadata") or {}
                ).get("annotations") or {}
                check(
                    f"{prefix} no Knative annotations",
                    not any(key.startswith("autoscaling.knative.dev") for key in annotations),
                    annotations,
                )

        pod_spec = {}
        container = {}
        if workload is not None:
            pod_spec = ((workload.get("spec") or {}).get("template") or {}).get("spec") or {}
            containers = pod_spec.get("containers") or []
            container = containers[0] if containers else {}

        # ── PostgreSQL reuse ──────────────────────────────────────────────
        databases = [doc for doc in overlay if kind_of(doc) == "Database"]
        if args.postgres:
            check(f"{prefix} Database CR present", len(databases) == 1, f"count={len(databases)}")
            if databases:
                database = databases[0]
                check(f"{prefix} Database apiVersion", api_of(database) == "postgresql.cnpg.io/v1", api_of(database))
                check(f"{prefix} Database name", name_of(database) == args.svc, name_of(database))
                spec = database.get("spec") or {}
                check(f"{prefix} Database spec.name", spec.get("name") == args.db_name, spec.get("name"))
                check(
                    f"{prefix} Database cluster name",
                    ((spec.get("cluster") or {}).get("name")) == f"{args.project}-postgres",
                    (spec.get("cluster") or {}).get("name"),
                )
                check(f"{prefix} Database owner", spec.get("owner") == "app", spec.get("owner"))
                check(f"{prefix} Database ensure", spec.get("ensure") == "present", spec.get("ensure"))
            forbidden = {
                "Cluster",
                "Pooler",
                "ScheduledBackup",
                "ObjectStore",
            }
            check(
                f"{prefix} no CNPG Cluster/Pooler/backup CR",
                not any(kind_of(doc) in forbidden for doc in overlay),
            )

            container_env = env_map(container)
            database_env = container_env.get("APP__POSTGRES__DATABASE") or {}
            check(f"{prefix} PG database env", database_env.get("value") == args.db_name, database_env.get("value"))
            url_env = container_env.get("APP__POSTGRES__URL") or {}
            url_ref = secret_ref(url_env)
            check(
                f"{prefix} PG URL secret ref",
                url_ref.get("name") == f"{args.project}-postgres-app" and url_ref.get("key") == "uri",
                url_ref,
            )
            host_env = container_env.get("APP__POSTGRES__HOST") or {}
            pooler = f"{args.project}-postgres-rw-pooler"
            if pooler:
                check(f"{prefix} PG host pooler env", host_env.get("value") == pooler, host_env.get("value"))
            else:
                check(f"{prefix} PG host omitted", "APP__POSTGRES__HOST" not in container_env)

            mounts = {
                (mount.get("name")): mount
                for mount in (container.get("volumeMounts") or [])
                if isinstance(mount, dict)
            }
            ca_mount = mounts.get("postgres-ca") or {}
            check(f"{prefix} PG CA mount path", ca_mount.get("mountPath") == "/etc/secrets/pg-ca", ca_mount)
            check(f"{prefix} PG CA mount readOnly", ca_mount.get("readOnly") is True, ca_mount)
            volumes = {
                (volume.get("name")): volume
                for volume in (pod_spec.get("volumes") or [])
                if isinstance(volume, dict)
            }
            ca_volume = volumes.get("postgres-ca") or {}
            secret = ca_volume.get("secret") or {}
            check(f"{prefix} PG CA secret name", secret.get("secretName") == f"{args.project}-postgres-ca", secret)
            items = secret.get("items") or []
            check(
                f"{prefix} PG CA secret item",
                any(item.get("key") == "ca.crt" and item.get("path") == "ca.crt" for item in items if isinstance(item, dict)),
                items,
            )
        else:
            check(f"{prefix} no Database CR", len(databases) == 0, f"count={len(databases)}")
            container_env = env_map(container)
            check(
                f"{prefix} no PG env",
                not any(key.startswith("APP__POSTGRES__") for key in container_env),
                sorted(container_env),
            )
            check(
                f"{prefix} no PG CA mount",
                not any((mount.get("name") == "postgres-ca") for mount in (container.get("volumeMounts") or []) if isinstance(mount, dict)),
            )

        # ── S3 reuse ──────────────────────────────────────────────────────
        container_env = env_map(container)
        if args.s3:
            access = secret_ref(container_env.get("AWS_ACCESS_KEY_ID") or {})
            secret_key = secret_ref(container_env.get("AWS_SECRET_ACCESS_KEY") or {})
            bucket_host = configmap_ref(container_env.get("BUCKET_HOST") or {})
            bucket_port = configmap_ref(container_env.get("BUCKET_PORT") or {})
            bucket_name = configmap_ref(container_env.get("APP__S3__BUCKET") or {})
            check(
                f"{prefix} S3 access key ref",
                access.get("name") == f"{args.project}-app-data" and access.get("key") == "AWS_ACCESS_KEY_ID",
                access,
            )
            check(
                f"{prefix} S3 secret key ref",
                secret_key.get("name") == f"{args.project}-app-data" and secret_key.get("key") == "AWS_SECRET_ACCESS_KEY",
                secret_key,
            )
            check(
                f"{prefix} S3 bucket host ref",
                bucket_host.get("name") == f"{args.project}-app-data" and bucket_host.get("key") == "BUCKET_HOST",
                bucket_host,
            )
            check(
                f"{prefix} S3 bucket port ref",
                bucket_port.get("name") == f"{args.project}-app-data" and bucket_port.get("key") == "BUCKET_PORT",
                bucket_port,
            )
            endpoint_env = container_env.get("APP__S3__ENDPOINT") or {}
            check(
                f"{prefix} S3 endpoint",
                endpoint_env.get("value") == "http://$(BUCKET_HOST):$(BUCKET_PORT)",
                endpoint_env.get("value"),
            )
            check(
                f"{prefix} S3 bucket name ref",
                bucket_name.get("name") == f"{args.project}-app-data" and bucket_name.get("key") == "BUCKET_NAME",
                bucket_name,
            )
        else:
            check(
                f"{prefix} no S3 env",
                not any(key.startswith("APP__S3__") or key in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "BUCKET_HOST", "BUCKET_PORT") for key in container_env),
                sorted(container_env),
            )

        # ── Kafka publish/source ──────────────────────────────────────────
        broker_env = container_env.get("APP__KAFKA__BROKER_URL") or {}
        if args.kafka_publish or args.kafka_source:
            check(f"{prefix} Kafka broker env", broker_env.get("value") == kafka[env], broker_env.get("value"))
        else:
            check(f"{prefix} no Kafka broker env", "APP__KAFKA__BROKER_URL" not in container_env)

        sources = ((values.get("kafka") or {}).get("sources") or {})
        post_renderers = release.get("spec", {}).get("postRenderers") or []
        dlq_target = f"{args.svc}-{args.svc}-events-dlq"
        if effective_source:
            check(f"{prefix} kafka.sources values", bool(sources))
            patch_target = None
            patch_body = None
            if post_renderers:
                patches = ((post_renderers[0].get("kustomize") or {}).get("patches") or [])
                if patches:
                    patch_target = (patches[0].get("target") or {}).get("name")
                    patch_body = patches[0].get("patch")
            check(f"{prefix} DLQ postRenderer target", patch_target == dlq_target, patch_target)
            check(
                f"{prefix} DLQ postRenderer strips env",
                isinstance(patch_body, str)
                and "/spec/template/spec/containers/0/env" in patch_body
                and "value: []" in patch_body,
                patch_body,
            )
            if kafka_sources:
                source = kafka_sources[0]
                sink_ref = (((source.get("spec") or {}).get("sink") or {}).get("ref") or {})
                check(f"{prefix} KafkaSource sink", sink_ref.get("name") == args.svc, sink_ref)
                dead_letter = ((((source.get("spec") or {}).get("delivery") or {}).get("deadLetterSink") or {}).get("ref") or {})
                check(f"{prefix} KafkaSource DLQ ref", dead_letter.get("name") == dlq_target, dead_letter)
            dlq_services = [
                doc
                for doc in chart
                if kind_of(doc) == "Service" and name_of(doc) == dlq_target
            ]
            if dlq_services:
                dlq_pod = (((dlq_services[0].get("spec") or {}).get("template") or {}).get("spec") or {})
                dlq_containers = dlq_pod.get("containers") or [{}]
                dlq_env = env_map(dlq_containers[0])
                check(
                    f"{prefix} DLQ raw env needs postRenderer",
                    any((entry.get("valueFrom") or {}).get("fieldRef") for entry in dlq_env.values()),
                )
        else:
            check(f"{prefix} no kafka.sources values", not sources)
            check(f"{prefix} no postRenderers", not post_renderers)

        # ── Per-env env/namespace contract ────────────────────────────────
        telemetry = (container_env.get("APP__TELEMETRY__SERVICE_NAME") or {}).get("value")
        expected_telemetry = f"{args.svc}-dev" if env == "dev" else args.svc
        check(f"{prefix} telemetry service name", telemetry == expected_telemetry, telemetry)

        redis_env = container_env.get("APP__REDIS__URL") or {}
        if env == "dev":
            check(
                f"{prefix} dev Redis literal",
                str(redis_env.get("value", "")).startswith("redis://redis."),
                redis_env.get("value"),
            )
        else:
            redis_ref = secret_ref(redis_env)
            check(
                f"{prefix} project Redis secret ref",
                redis_ref.get("name") == f"{args.project}-secrets" and redis_ref.get("key") == "redis-url",
                redis_ref,
            )

        # ── No unrendered Liquid in rendered output ───────────────────────
        for rendered in (overlay_path, chart_path):
            text = open(rendered, encoding="utf-8").read()
            check(f"{prefix} no Liquid in {os.path.basename(rendered)}", LIQUID_OPEN not in text and LIQUID_TAG not in text)

    # ── Image updates ─────────────────────────────────────────────────────
    flux_path = os.path.join(args.render_dir, "flux.yaml")
    if args.image_updates:
        check("image updates flux render present", os.path.isfile(flux_path))
        if os.path.isfile(flux_path):
            try:
                flux = load_docs(flux_path)
                check("flux YAML parses", True)
            except Exception as exc:  # noqa: BLE001
                check("flux YAML parses", False, repr(exc))
                flux = []
            repositories = [doc for doc in flux if kind_of(doc) == "ImageRepository"]
            policies = [doc for doc in flux if kind_of(doc) == "ImagePolicy"]
            check("ImageRepository count", len(repositories) == 1, f"count={len(repositories)}")
            if repositories:
                repository = repositories[0]
                check("ImageRepository name", name_of(repository) == f"{args.project}-{args.svc}", name_of(repository))
                check("ImageRepository namespace", (repository.get("metadata") or {}).get("namespace") == "flux-system")
                check(
                    "ImageRepository image",
                    (repository.get("spec") or {}).get("image") == f"{args.registry}/{args.org}/{args.project}-{args.svc}",
                    (repository.get("spec") or {}).get("image"),
                )
            expected_policies = {f"{args.project}-{args.svc}", f"{args.project}-{args.svc}-release"}
            check(
                "ImagePolicy names",
                {name_of(policy) for policy in policies} == expected_policies,
                sorted(name_of(policy) for policy in policies),
            )
            check("no per-service ImageUpdateAutomation", not any(kind_of(doc) == "ImageUpdateAutomation" for doc in flux))
            marker = '{"$imagepolicy": "flux-system:%s-%s:tag"}' % (args.project, args.svc)
            check("image marker exact", marker in base_text, marker)
    else:
        check("no flux dir without image updates", not os.path.isdir(os.path.join(args.svc_dir, "deploy/flux")))

    # ── No unrendered Liquid in the generated service tree ────────────────
    leftovers = []
    for directory, _, files in os.walk(args.svc_dir):
        for filename in files:
            path = os.path.join(directory, filename)
            try:
                text = open(path, encoding="utf-8", errors="ignore").read()
            except OSError:
                continue
            if LIQUID_OPEN in text or LIQUID_TAG in text:
                leftovers.append(os.path.relpath(path, args.svc_dir))
    check("no unrendered Liquid in service tree", not leftovers, leftovers)

    # ── Snake-case normalisation ──────────────────────────────────────────
    if "_" in args.svc_slug:
        check("snake slug normalises to kebab", args.svc == args.svc_slug.replace("_", "-"), args.svc)
        for env in ENVS:
            overlay = load_docs(os.path.join(args.render_dir, env, "overlay.yaml"))
            bad = [name_of(doc) for doc in overlay if name_of(doc) and "_" in name_of(doc)]
            check(f"snake/{env} no underscore resource names", not bad, bad)
        check("snake HelmRelease kebab", f"name: {args.svc}" in base_text)
        check("snake image repository kebab", f"{args.project}-{args.svc}" in base_text)
        databases = [doc for doc in load_docs(os.path.join(args.render_dir, "dev", "overlay.yaml")) if kind_of(doc) == "Database"]
        if databases:
            check("snake Database spec.name keeps db_name", (databases[0].get("spec") or {}).get("name") == args.db_name, (databases[0].get("spec") or {}).get("name"))

    if failures:
        print(f"SUMMARY {args.name} failures={failures}")
        return 1
    print(f"PASS {args.name} variant")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
}

run_verifier() {
	local render_dir="$1" platform_dir="$2"
	local kind="knative"
	[[ "$V_DEPLOY" == "1" ]] && kind="deployment"
	local base_hr="$platform_dir/deploy/base/helmrelease.yaml"
	local out rc
	if out="$(python3 "$WORKDIR/verify.py" \
		--name "$V_NAME" \
		--kind "$kind" \
		--svc "$SVC_NAME" \
		--svc-slug "$V_SVC_SLUG" \
		--svc-dir "$platform_dir" \
		--render-dir "$render_dir" \
		--base-hr "$base_hr" \
		--project "$V_PROJECT" \
		--registry "$IMAGE_REGISTRY" \
		--org "$GITHUB_ORG" \
		--db-name "$V_DB" \
		--postgres "$V_PG" \
		--s3 "$V_S3" \
		--kafka-publish "$V_PUB" \
		--kafka-source "$V_SRC" \
		--flagger "$V_FLAGGER" \
		--image-updates "$V_IMG" \
		--pdb "$V_PDB" \
		--ns-dev "$V_PROJECT-dev" \
		--ns-staging "$V_PROJECT-staging" \
		--ns-prod "$V_PROJECT-prod" \
		--kafka-dev "$KAFKA_DEV" \
		--kafka-staging "$KAFKA_STAGING" \
		--kafka-prod "$KAFKA_PROD" \
		--prom-dev "$PROM_DEV" \
		--prom-staging "$PROM_STAGING" \
		--prom-prod "$PROM_PROD" \
		2>&1)"; then
		rc=0
	else
		rc=$?
	fi
	printf '%s\n' "$out"
	local p f
	p="$(printf '%s\n' "$out" | grep -c '^PASS ' || true)"
	f="$(printf '%s\n' "$out" | grep -c '^FAIL ' || true)"
	PASS=$((PASS + p))
	FAIL=$((FAIL + f))
	if [[ "$rc" -eq 0 ]]; then
		printf 'PASS variant %s (%s checks)\n' "$V_NAME" "$p"
	else
		printf 'FAIL variant %s (%s checks, %s failures)\n' "$V_NAME" "$p" "$f" >&2
	fi
}

# ── Variant driver ────────────────────────────────────────────────────────

run_variant() {
	VARIANTS=$((VARIANTS + 1))
	SVC_NAME="${V_SVC_SLUG//_/-}"
	V_PG_BOOL="$(bool "$V_PG")"
	V_S3_BOOL="$(bool "$V_S3")"
	V_PUB_BOOL="$(bool "$V_PUB")"
	V_SRC_BOOL="$(bool "$V_SRC")"
	V_DEPLOY_BOOL="$(bool "$V_DEPLOY")"
	V_FLAGGER_BOOL="$(bool "$V_FLAGGER")"
	V_IMG_BOOL="$(bool "$V_IMG")"

	local values="$WORKDIR/values/$V_NAME.toml"
	local platform_dir="$V_PLATFORM/services/$V_SVC_DIR"
	local render_dir="$WORKDIR/renders/$V_NAME"
	mkdir -p "$render_dir"
	write_service_values "$values"

	if ! gen_service "$V_PLATFORM" "$V_SVC_DIR" "$V_SVC_SLUG" "$values"; then
		fail "variant $V_NAME (generation)"
		return
	fi

	# The service-template hardcodes PDB enabled; the off case is a deliberate
	# values override on the generated fixture (the chart exposes no toggle in
	# the template placeholder contract).
	if [[ "$V_PDB" == "off" ]]; then
		yq -i '.spec.values.services.app.podDisruptionBudget.enabled = false' \
			"$platform_dir/deploy/base/helmrelease.yaml"
	fi

	if ! render_variant "$V_PLATFORM" "$V_SVC_DIR" "$render_dir"; then
		fail "variant $V_NAME (render)"
		return
	fi

	run_verifier "$render_dir" "$platform_dir"
}

# v <name> <platform> <svc-dir> <svc-slug> <project> <db> <pg> <s3> <pub> <src> <deploy> <flagger> <img> <pdb>
v() {
	V_NAME="$1"
	V_PLATFORM="$2"
	V_SVC_DIR="$3"
	V_SVC_SLUG="$4"
	V_PROJECT="$5"
	V_DB="$6"
	V_PG="$7"
	V_S3="$8"
	V_PUB="$9"
	V_SRC="${10}"
	V_DEPLOY="${11}"
	V_FLAGGER="${12}"
	V_IMG="${13}"
	V_PDB="${14}"
	run_variant
}

# ── Main ──────────────────────────────────────────────────────────────────

printf 'Service render matrix (no cluster)\n'
printf '  template: %s\n' "$TEMPLATE_PATH"
printf '  workdir:  %s\n' "$WORKDIR"

write_verifier

PLATFORM_TEMPLATE="$(prepare_platform_template "$PLATFORM_TEMPLATE")"
printf '  platform snapshot: %s\n' "$PLATFORM_TEMPLATE"

FULL_PLATFORM="$WORKDIR/platform/test-app-full"
KAFKA_OFF_PLATFORM="$WORKDIR/platform/test-app-kafka-off"

write_platform_values "$WORKDIR/values/platform-full.toml" "test-app-full" true true
write_platform_values "$WORKDIR/values/platform-kafka-off.toml" "test-app-kafka-off" false false

gen_platform "test-app-full" "$WORKDIR/values/platform-full.toml" "$FULL_PLATFORM"
gen_platform "test-app-kafka-off" "$WORKDIR/values/platform-kafka-off.toml" "$KAFKA_OFF_PLATFORM"

CHART_DIR="$FULL_PLATFORM/deploy/chart"
if ! helm dependency build "$CHART_DIR" >"$WORKDIR/helm-dependency.log" 2>&1; then
	tail -40 "$WORKDIR/helm-dependency.log" >&2
	die "helm dependency build failed for $CHART_DIR"
fi

# Knative x optional infrastructure.
v knative-none "$FULL_PLATFORM" svc-knative-none svc-knative-none test-app-full svc_knative_none 0 0 0 0 0 0 0 off
v knative-postgres "$FULL_PLATFORM" svc-knative-pg svc-knative-pg test-app-full svc_knative_pg 1 0 0 0 0 0 0 off
v knative-s3 "$FULL_PLATFORM" svc-knative-s3 svc-knative-s3 test-app-full svc_knative_s3 0 1 0 0 0 0 0 off
v knative-kafka-publish "$FULL_PLATFORM" svc-knative-pub svc-knative-pub test-app-full svc_knative_pub 0 0 1 0 0 0 0 off
v knative-kafka-source "$FULL_PLATFORM" svc-knative-src svc-knative-src test-app-full svc_knative_src 0 0 1 1 0 0 0 off
v knative-flagger "$FULL_PLATFORM" svc-knative-canary svc-knative-canary test-app-full svc_knative_canary 0 0 0 0 0 1 0 off

# Deployment x optional infrastructure, including PDB on/off.
v deploy-pdb-on "$FULL_PLATFORM" svc-deploy-pdb svc-deploy-pdb test-app-full svc_deploy_pdb 0 0 0 0 1 0 0 on
v deploy-pdb-off "$FULL_PLATFORM" svc-deploy-nopdb svc-deploy-nopdb test-app-full svc_deploy_nopdb 0 0 0 0 1 0 0 off
v deploy-postgres "$FULL_PLATFORM" svc-deploy-pg svc-deploy-pg test-app-full svc_deploy_pg 1 0 0 0 1 0 0 on
v deploy-s3 "$FULL_PLATFORM" svc-deploy-s3 svc-deploy-s3 test-app-full svc_deploy_s3 0 1 0 0 1 0 0 on
v deploy-kafka-publish "$FULL_PLATFORM" svc-deploy-pub svc-deploy-pub test-app-full svc_deploy_pub 0 0 1 0 1 0 0 on

# Limitation: Deployment + kafka_source + flagger must render publisher-only.
v deploy-kafka-source-limited "$FULL_PLATFORM" svc-deploy-src svc-deploy-src test-app-full svc_deploy_src 0 0 1 1 1 1 0 on

# feature_kafka=false platform + kafka publish (publisher-only).
v kafka-off-platform-publish "$KAFKA_OFF_PLATFORM" svc-kafka-off-pub svc-kafka-off-pub test-app-kafka-off svc_kafka_off_pub 0 0 1 0 0 0 0 off

# Snake-case input normalisation (service_slug keeps underscores, K8s names do not).
v snake-case "$FULL_PLATFORM" orders-api orders_api test-app-full orders_api 1 0 0 0 0 0 0 off

# Image-update resources.
v image-updates "$FULL_PLATFORM" svc-image-updates svc-image-updates test-app-full svc_image_updates 1 0 0 0 0 0 1 off

# ── Negative check: the wrapper forces kafka_source off for Deployment ────
add_service_out="$(
	cd "$FULL_PLATFORM" && bash scripts/add-service.sh \
		--name probe --workload deployment --kafka-publish --kafka-source --dry-run 2>&1
)" || true
if [[ "$add_service_out" == *"kafka_source forced off"* ]]; then
	pass "negative add-service forces kafka_source off for Deployment"
else
	fail "negative add-service forces kafka_source off for Deployment"
fi
if grep -Eq 'kafka_source[[:space:]]*=[[:space:]]*false' <<<"$add_service_out"; then
	pass "negative add-service reports kafka_source=false"
else
	fail "negative add-service reports kafka_source=false"
fi
if grep -Eq 'workload_deployment[[:space:]]*=[[:space:]]*true' <<<"$add_service_out"; then
	pass "negative add-service reports workload_deployment=true"
else
	fail "negative add-service reports workload_deployment=true"
fi

printf '\nTOTAL variants=%s pass=%s fail=%s\n' "$VARIANTS" "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
	exit 1
fi
if [[ "$VARIANTS" -lt 8 ]]; then
	printf 'FAIL matrix covers %s variants (need >= 8)\n' "$VARIANTS" >&2
	exit 1
fi
printf 'PASS render matrix (%s variants)\n' "$VARIANTS"
