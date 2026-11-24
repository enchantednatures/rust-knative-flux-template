#!/usr/bin/env bash
#
# add-service.sh - detect a generated project's existing infrastructure and
# compute the service-template values for a new service.
#
# This helper detects everything from LOCAL MANIFESTS, validates the requested
# options, generates the service with cargo-generate, appends the workspace
# member, and registers the service's deploy subtree in each root overlay.
# `--dry-run` prints the plan without writing or generating anything.
#
# Cluster probing is OPT-IN: `--probe-cluster` performs read-only kubectl
# queries for CNPG/Kafka/Redpanda; the default never reads a kubeconfig.
#
# Usage:
#   scripts/add-service.sh --name orders-api [options]
#
# Options:
#   --name <slug>                 Service slug (kebab-case; required)
#   --workload knative|deployment Workload kind (default: knative)
#   --postgres / --no-postgres    Reuse the CNPG cluster
#   --s3 / --no-s3                Reuse the project app-data bucket claim
#   --kafka-publish / --no-kafka-publish
#                                 Publish events to Kafka
#   --kafka-source / --no-kafka-source
#                                 Consume events via a Knative KafkaSource
#   --enable-flagger / --no-flagger
#                                 Enable Flagger canary promotion (Knative only)
#   --kafka-broker <host:port>    Override the detected broker for all envs
#                                 (alias: --kafka-broker-url)
#   --probe-cluster               Probe the current cluster read-only (opt-in)
#   --no-probe                    Compatibility no-op (probing is off by default)
#   --dry-run                     Print the plan; change nothing
#   --force                       Allow a planned overwrite of a non-empty
#                                 services/<slug> directory
#   --help                        Show this help
#
# Environment overrides:
#   KAFKA_BROKER_URL              Same as --kafka-broker
#   TEMPLATE_GIT_URL              Overrides TEMPLATE_REPO_URL from
#                                 scripts/service-template.env
#   SERVICE_TEMPLATE_REF          Overrides TEMPLATE_REF from that file
#
# Requires: bash, yq (mikefarah v4). python3 is used when cargo metadata works,
# with a manifest-parsing fallback.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

NAME=""
WORKLOAD="knative"
POSTGRES_SET=""
S3_SET=""
KAFKA_PUBLISH_SET=""
KAFKA_SOURCE_SET=""
FLAGGER_SET=""
KAFKA_BROKER_OVERRIDE="${KAFKA_BROKER_URL:-}"
PROBE_CLUSTER=0
DRY_RUN=0
FORCE=0

usage() {
	sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'
}

need_value() {
	local flag="$1"
	local value="${2:-}"
	if [[ -z "$value" ]]; then
		echo "Error: $flag requires a value" >&2
		exit 2
	fi
	REPLY="$value"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--name)
			need_value "$1" "${2:-}"; NAME="$REPLY"; shift 2 ;;
		--name=*)
			NAME="${1#*=}"; shift ;;
		--workload)
			need_value "$1" "${2:-}"; WORKLOAD="$REPLY"; shift 2 ;;
		--workload=*)
			WORKLOAD="${1#*=}"; shift ;;
		--postgres)
			POSTGRES_SET=true; shift ;;
		--no-postgres)
			POSTGRES_SET=false; shift ;;
		--s3)
			S3_SET=true; shift ;;
		--no-s3)
			S3_SET=false; shift ;;
		--kafka-publish)
			KAFKA_PUBLISH_SET=true; shift ;;
		--no-kafka-publish)
			KAFKA_PUBLISH_SET=false; shift ;;
		--kafka-source)
			KAFKA_SOURCE_SET=true; shift ;;
		--no-kafka-source)
			KAFKA_SOURCE_SET=false; shift ;;
		--enable-flagger)
			FLAGGER_SET=true; shift ;;
		--no-flagger|--no-enable-flagger)
			FLAGGER_SET=false; shift ;;
		--kafka-broker|--kafka-broker-url)
			need_value "$1" "${2:-}"; KAFKA_BROKER_OVERRIDE="$REPLY"; shift 2 ;;
		--kafka-broker=*|--kafka-broker-url=*)
			KAFKA_BROKER_OVERRIDE="${1#*=}"; shift ;;
		--probe-cluster)
			PROBE_CLUSTER=1; shift ;;
		--no-probe)
			PROBE_CLUSTER=0; shift ;;
		--dry-run)
			DRY_RUN=1; shift ;;
		--force)
			FORCE=1; shift ;;
		--help|-h)
			usage; exit 0 ;;
		--)
			shift; break ;;
		*)
			echo "Error: unknown option: $1" >&2
			echo "Run '$0 --help' for usage." >&2
			exit 2 ;;
	esac
done

case "$WORKLOAD" in
	knative|deployment) ;;
	*)
		echo "Error: --workload must be 'knative' or 'deployment' (got '$WORKLOAD')" >&2
		exit 2 ;;
esac

if [[ -z "$NAME" ]]; then
	echo "Error: --name <service-slug> is required" >&2
	echo "Run '$0 --help' for usage." >&2
	exit 2
fi

if ! command -v yq >/dev/null 2>&1; then
	echo "Error: yq (mikefarah v4) is required for manifest detection" >&2
	exit 1
fi

if [[ ! -f "$ROOT/Cargo.toml" || ! -f "$ROOT/deploy/base/helmrelease.yaml" ]]; then
	echo "Error: $ROOT does not look like a generated project" >&2
	echo "Expected Cargo.toml and deploy/base/helmrelease.yaml." >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

warn() { echo "Warning: $*" >&2; }

# yq_get <expression> <file> - first non-null result, empty when absent.
yq_get() {
	local expr="$1" file="$2" value=""
	[[ -f "$file" ]] || return 0
	value="$(yq e "$expr" "$file" 2>/dev/null | head -n 1)" || value=""
	[[ "$value" == "null" ]] && value=""
	printf '%s' "$value"
}

# text_env_value <file> <ENV_NAME> - read `value:` for an env entry in a
# kustomize JSON6902 patch string (the overlay `env` list is not structured).
text_env_value() {
	local file="$1" key="$2"
	[[ -f "$file" ]] || return 0
	awk -v key="$key" '
		index($0, "- name: " key) > 0 { want = 1; next }
		want && /^[[:space:]]*-[[:space:]]*name:/ { want = 0 }
		want && /^[[:space:]]*value:/ {
			line = $0
			sub(/^[[:space:]]*value:[[:space:]]*/, "", line)
			gsub(/^["'\'']|["'\'']$/, "", line)
			print line
			exit
		}
	' "$file"
}

# overlay_bootstrap <file> - first broker after a bootstrapServers patch key.
overlay_bootstrap() {
	local file="$1"
	[[ -f "$file" ]] || return 0
	awk '
		/bootstrapServers/ { want = 1; next }
		want && /^[[:space:]]*-[[:space:]]*"?[^"[:space:]]+:[0-9]+"?[[:space:]]*$/ {
			line = $0
			sub(/^[[:space:]]*-[[:space:]]*"?/, "", line)
			sub(/"?[[:space:]]*$/, "", line)
			print line
			exit
		}
	' "$file"
}

# overlay_provider_address <file> - MetricTemplate.spec.provider.address patch.
overlay_provider_address() {
	local file="$1"
	[[ -f "$file" ]] || return 0
	awk '
		/provider\/address/ { want = 1; next }
		want && /^[[:space:]]*value:/ {
			line = $0
			sub(/^[[:space:]]*value:[[:space:]]*/, "", line)
			gsub(/^["'\'']|["'\'']$/, "", line)
			print line
			exit
		}
	' "$file"
}

# toml_kafka_broker <file> - broker_url inside a rendered [kafka] table.
toml_kafka_broker() {
	local file="$1"
	[[ -f "$file" ]] || return 0
	awk '
		/^[[:space:]]*\[kafka\][[:space:]]*$/ { in_kafka = 1; next }
		/^[[:space:]]*\[/ { in_kafka = 0 }
		in_kafka && /^[[:space:]]*broker_url[[:space:]]*=/ {
			line = $0
			sub(/^[^=]*=[[:space:]]*/, "", line)
			sub(/[[:space:]]*#.*$/, "", line)
			gsub(/^["'\'']|["'\'']$/, "", line)
			print line
			exit
		}
	' "$file"
}

# app_data_storage_class <file> - storageClassName for the app-data claim.
app_data_storage_class() {
	local file="$1"
	[[ -f "$file" ]] || return 0
	awk '
		/^[[:space:]]+app-data:[[:space:]]*$/ { want = 1; next }
		want && /storageClassName:/ {
			line = $0
			sub(/^[^:]*:[[:space:]]*/, "", line)
			gsub(/^["'\'']|["'\'']$/, "", line)
			print line
			exit
		}
		want && /^[[:space:]]*[A-Za-z0-9_-]+:[[:space:]]*$/ { want = 0 }
	' "$file"
}

env_file_value() {
	local key="$1" file="$2" line=""
	[[ -f "$file" ]] || return 0
	line="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$file" | tail -n 1)"
	line="${line%\"}"; line="${line#\"}"
	line="${line%\'}"; line="${line#\'}"
	printf '%s' "$line"
}

workspace_packages() {
	local meta="" file="" name=""
	# Only use cargo metadata when a lockfile already exists and cannot be
	# modified (--locked): --dry-run must never write to the repository.
	if [[ -f "$ROOT/Cargo.lock" ]] && command -v cargo >/dev/null 2>&1; then
		meta="$(cargo metadata --no-deps --locked --offline --format-version 1 2>/dev/null || true)"
	fi
	if [[ -n "$meta" ]] && command -v python3 >/dev/null 2>&1; then
		printf '%s' "$meta" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for package in data.get("packages", []):
    name = package.get("name")
    if name:
        print(name)
' && return 0
	fi
	# Fallback: read package names straight from the workspace manifests.
	for file in "$ROOT/Cargo.toml" "$ROOT"/crates/*/Cargo.toml "$ROOT"/services/*/Cargo.toml; do
		[[ -f "$file" ]] || continue
		name="$(sed -n '/^\[package\]/,/^\[/s/^name[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n 1)"
		[[ -n "$name" ]] && printf '%s\n' "$name"
	done
}

# ---------------------------------------------------------------------------
# Detection (local manifests only; no kubectl)
# ---------------------------------------------------------------------------

BASE_HR="$ROOT/deploy/base/helmrelease.yaml"
OVERLAYS="$ROOT/deploy/overlays"

PROJECT_SLUG="$(yq_get 'select(.kind == "HelmRelease") | .metadata.name' "$BASE_HR")"
if [[ -z "$PROJECT_SLUG" ]]; then
	PROJECT_SLUG="$(yq_get 'select(.kind == "HelmRelease") | .spec.values.global.fullnameOverride' "$BASE_HR")"
fi

IMAGE_REPO_REF="$(yq_get 'select(.kind == "HelmRelease") | .spec.values.services.app.image.repository' "$BASE_HR")"
if [[ -z "$IMAGE_REPO_REF" ]]; then
	IMAGE_REPO_REF="$(yq_get 'select(.kind == "HelmRelease") | .spec.values.services | to_entries | .[0].value.image.repository' "$BASE_HR")"
fi
if [[ -z "$PROJECT_SLUG" && -n "$IMAGE_REPO_REF" ]]; then
	PROJECT_SLUG="${IMAGE_REPO_REF##*/}"
fi
PROJECT_SLUG="${PROJECT_SLUG//_/-}"

IMAGE_REGISTRY=""
GITHUB_ORG=""
IMAGE_REPO=""
if [[ -n "$IMAGE_REPO_REF" ]]; then
	IFS='/' read -r -a _img <<< "$IMAGE_REPO_REF"
	_n=${#_img[@]}
	(( _n >= 1 )) && IMAGE_REGISTRY="${_img[0]}"
	(( _n >= 2 )) && GITHUB_ORG="${_img[1]}"
	(( _n >= 1 )) && IMAGE_REPO="${_img[$((_n - 1))]}"
fi
[[ -z "$IMAGE_REGISTRY" ]] && IMAGE_REGISTRY="ghcr.io"
[[ -z "$GITHUB_ORG" ]] && GITHUB_ORG="your-org"
[[ -z "$IMAGE_REPO" ]] && IMAGE_REPO="$PROJECT_SLUG"

env_namespace() {
	local env_name="$1"
	local overlay="$OVERLAYS/$env_name/kustomization.yaml"
	local ns=""
	ns="$(yq_get '.namespace' "$overlay")"
	if [[ -z "$ns" && -f "$OVERLAYS/$env_name/namespace.yaml" ]]; then
		ns="$(yq_get 'select(.kind == "Namespace") | .metadata.name' "$OVERLAYS/$env_name/namespace.yaml")"
	fi
	[[ -z "$ns" ]] && ns="default"
	printf '%s' "$ns"
}

NS_DEV="$(env_namespace dev)"
NS_STAGING="$(env_namespace staging)"
NS_PROD="$(env_namespace prod)"

PG_CLUSTER=""
PG_CLUSTER_SRC="default"
PG_CLUSTER_PRESENT=false
PG_FILE="$ROOT/deploy/components/postgres/postgres-cluster.yaml"
if [[ -f "$PG_FILE" ]]; then
	PG_CLUSTER="$(yq_get 'select(.kind == "Cluster") | .metadata.name' "$PG_FILE")"
	if [[ -n "$PG_CLUSTER" ]]; then
		PG_CLUSTER_SRC="repo"
		PG_CLUSTER_PRESENT=true
	fi
fi
[[ -z "$PG_CLUSTER" ]] && PG_CLUSTER="$PROJECT_SLUG-postgres"

PG_POOLER_HOST=""
PG_POOLER_SRC="default"
PG_POOLER_FILE="$ROOT/deploy/components/postgres-pooler/postgres-pooler.yaml"
if [[ -f "$PG_POOLER_FILE" ]]; then
	PG_POOLER_HOST="$(yq_get 'select(.kind == "Pooler") | .metadata.name' "$PG_POOLER_FILE")"
	[[ -n "$PG_POOLER_HOST" ]] && PG_POOLER_SRC="repo"
fi

PG_APP_SECRET="$(yq_get 'select(.kind == "HelmRelease") | .spec.values.services.app.env[] | select(.name == "APP__POSTGRES__URL") | .valueFrom.secretKeyRef.name' "$BASE_HR")"
PG_APP_SECRET_SRC="default"
if [[ -n "$PG_APP_SECRET" ]]; then
	PG_APP_SECRET_SRC="repo"
else
	PG_APP_SECRET="${PG_CLUSTER}-app"
fi

PG_CA_SECRET="$(yq_get 'select(.kind == "HelmRelease") | .spec.values.services.app.volumes[] | select(.secret != null) | .secret.secretName' "$BASE_HR")"
PG_CA_SECRET_SRC="default"
if [[ -n "$PG_CA_SECRET" ]]; then
	PG_CA_SECRET_SRC="repo"
else
	PG_CA_SECRET="${PG_CLUSTER}-ca"
fi

REDIS_URL="$(text_env_value "$OVERLAYS/dev/kustomization.yaml" "APP__REDIS__URL")"
REDIS_SRC="repo"
if [[ -z "$REDIS_URL" ]]; then
	REDIS_URL="redis://redis.default.svc.cluster.local:6379"
	REDIS_SRC="default"
fi

OTEL_ENDPOINT="$(yq_get 'select(.kind == "HelmRelease") | .spec.values.services.app.env[] | select(.name == "APP__TELEMETRY__OTLP_ENDPOINT") | .value' "$BASE_HR")"
OTEL_SRC="repo"
if [[ -z "$OTEL_ENDPOINT" ]]; then
	OTEL_ENDPOINT="$(text_env_value "$OVERLAYS/dev/kustomization.yaml" "APP__TELEMETRY__OTLP_ENDPOINT")"
fi
if [[ -z "$OTEL_ENDPOINT" ]]; then
	OTEL_ENDPOINT="http://otel-collector.observability.svc.cluster.local:4317"
	OTEL_SRC="default"
fi

KAFKA_DEV_OVERLAY="$(text_env_value "$OVERLAYS/dev/kustomization.yaml" "APP__KAFKA__BROKER_URL")"
KAFKA_BASE_SOURCE="$(yq_get 'select(.kind == "HelmRelease") | .spec.values.kafka.sources | to_entries | .[0].value.bootstrapServers[0]' "$BASE_HR")"
KAFKA_CONFIG=""
for _cfg in "$ROOT/config/default.toml" "$ROOT/config/development.toml" "$ROOT/config/production.toml"; do
	KAFKA_CONFIG="$(toml_kafka_broker "$_cfg")"
	[[ -n "$KAFKA_CONFIG" ]] && break
done

KAFKA_BROKER=""
KAFKA_BROKER_SRC="default"
if [[ -n "$KAFKA_BROKER_OVERRIDE" ]]; then
	KAFKA_BROKER="$KAFKA_BROKER_OVERRIDE"
	KAFKA_BROKER_SRC="override"
elif [[ -n "$KAFKA_DEV_OVERLAY" ]]; then
	KAFKA_BROKER="$KAFKA_DEV_OVERLAY"
	KAFKA_BROKER_SRC="repo"
elif [[ -n "$KAFKA_BASE_SOURCE" ]]; then
	KAFKA_BROKER="$KAFKA_BASE_SOURCE"
	KAFKA_BROKER_SRC="repo"
elif [[ -n "$KAFKA_CONFIG" ]]; then
	KAFKA_BROKER="$KAFKA_CONFIG"
	KAFKA_BROKER_SRC="repo"
fi

KAFKA_STAGING="$(overlay_bootstrap "$OVERLAYS/staging/kustomization.yaml")"
KAFKA_STAGING_SRC="repo"
if [[ "$KAFKA_BROKER_SRC" == "override" ]]; then
	KAFKA_STAGING="$KAFKA_BROKER"
	KAFKA_STAGING_SRC="override"
elif [[ -z "$KAFKA_STAGING" ]]; then
	KAFKA_STAGING="$KAFKA_BROKER"
	KAFKA_STAGING_SRC="default"
fi
KAFKA_PROD="$(overlay_bootstrap "$OVERLAYS/prod/kustomization.yaml")"
KAFKA_PROD_SRC="repo"
if [[ "$KAFKA_BROKER_SRC" == "override" ]]; then
	KAFKA_PROD="$KAFKA_BROKER"
	KAFKA_PROD_SRC="override"
elif [[ -z "$KAFKA_PROD" ]]; then
	KAFKA_PROD="$KAFKA_BROKER"
	KAFKA_PROD_SRC="default"
fi
KAFKA_DEV="$KAFKA_BROKER"
KAFKA_DEV_SRC="$KAFKA_BROKER_SRC"

KAFKA_SOURCE_COUNT="$(yq_get 'select(.kind == "HelmRelease") | .spec.values.kafka.sources | length' "$BASE_HR")"
KAFKA_SOURCE_COUNT="${KAFKA_SOURCE_COUNT:-0}"
KAFKA_SOURCE_PRESENT=false
if [[ "$KAFKA_SOURCE_COUNT" =~ ^[0-9]+$ ]] && (( KAFKA_SOURCE_COUNT > 0 )); then
	KAFKA_SOURCE_PRESENT=true
elif [[ -f "$ROOT/deploy/base/kafka-source.yaml" ]]; then
	KAFKA_SOURCE_PRESENT=true
fi

APP_DATA_CLAIM=false
S3_STORAGE_CLASS=""
S3_SOURCE="default"
for _env in dev staging prod; do
	_overlay="$OVERLAYS/$_env/kustomization.yaml"
	[[ -f "$_overlay" ]] || continue
	if grep -qE '^[[:space:]]+app-data:[[:space:]]*$' "$_overlay"; then
		APP_DATA_CLAIM=true
		S3_STORAGE_CLASS="$(app_data_storage_class "$_overlay")"
		[[ -n "$S3_STORAGE_CLASS" ]] && S3_SOURCE="repo"
		break
	fi
done
if [[ "$APP_DATA_CLAIM" != true ]]; then
	_app_secret="$(yq_get 'select(.kind == "HelmRelease") | .spec.values.services.app.env[] | select(.valueFrom.secretKeyRef.name? // "" | endswith("-app-data")) | .valueFrom.secretKeyRef.name' "$BASE_HR")"
	if [[ -n "$_app_secret" ]]; then
		APP_DATA_CLAIM=true
		S3_SOURCE="repo"
	fi
fi
if [[ "$APP_DATA_CLAIM" != true ]]; then
	S3_STORAGE_CLASS="<none>"
elif [[ -z "$S3_STORAGE_CLASS" ]]; then
	S3_STORAGE_CLASS="ceph-bucket"
	S3_SOURCE="default"
fi

IMAGE_UPDATES=false
[[ -f "$ROOT/deploy/flux/image-policy.yaml" ]] && IMAGE_UPDATES=true

FLAGGER_OPERATOR=false
if [[ -f "$ROOT/deploy/flux/flagger-kustomization.yaml" ]] ||
	[[ -f "$ROOT/deploy/infrastructure/flagger/operator/helmrelease.yaml" ]] ||
	grep -q 'flagger-kustomization.yaml' "$ROOT"/deploy/flux/config/*/kustomization.yaml 2>/dev/null; then
	FLAGGER_OPERATOR=true
fi

CNPG_OPERATOR=false
if [[ -f "$ROOT/deploy/flux/cnpg-operator-kustomization.yaml" ]] ||
	[[ -f "$ROOT/deploy/infrastructure/cnpg-operator/kustomization.yaml" ]] ||
	grep -q 'cnpg-operator-kustomization.yaml' "$ROOT"/deploy/flux/config/*/kustomization.yaml 2>/dev/null; then
	CNPG_OPERATOR=true
fi

CANARY_DEV="http://prometheus.observability.svc.cluster.local:9090"
CANARY_DEV_SRC="default"
CANARY_STAGING="$(overlay_provider_address "$OVERLAYS/staging/kustomization.yaml")"
CANARY_STAGING_SRC="repo"
if [[ -z "$CANARY_STAGING" ]]; then
	CANARY_STAGING="$CANARY_DEV"
	CANARY_STAGING_SRC="default"
fi
CANARY_PROD="$(overlay_provider_address "$OVERLAYS/prod/kustomization.yaml")"
CANARY_PROD_SRC="repo"
if [[ -z "$CANARY_PROD" ]]; then
	CANARY_PROD="$CANARY_DEV"
	CANARY_PROD_SRC="default"
fi

# Template origin: scripts/service-template.env wins, environment overrides it.
TEMPLATE_ENV_FILE="$ROOT/scripts/service-template.env"
TEMPLATE_REPO_URL=""
TEMPLATE_REF=""
TEMPLATE_URL_SRC="repo"
TEMPLATE_REF_SRC="repo"

if [[ -f "$TEMPLATE_ENV_FILE" ]]; then
	TEMPLATE_REPO_URL="$(env_file_value TEMPLATE_REPO_URL "$TEMPLATE_ENV_FILE")"
	TEMPLATE_REF="$(env_file_value TEMPLATE_REF "$TEMPLATE_ENV_FILE")"
fi
if [[ -n "${TEMPLATE_GIT_URL:-}" ]]; then
	TEMPLATE_REPO_URL="$TEMPLATE_GIT_URL"
	TEMPLATE_URL_SRC="override"
fi
if [[ -n "${SERVICE_TEMPLATE_REF:-}" ]]; then
	TEMPLATE_REF="$SERVICE_TEMPLATE_REF"
	TEMPLATE_REF_SRC="override"
fi
OPEN='{'
if [[ -z "$TEMPLATE_REPO_URL" ]] || [[ "$TEMPLATE_REPO_URL" == *"$OPEN$OPEN"* ]]; then
	cat >&2 <<'EOF'
Error: cannot determine the service-template origin.

scripts/service-template.env is missing (or still contains Liquid placeholders).
Run this helper from a generated project, or set TEMPLATE_GIT_URL explicitly.
Refusing to fall back to this application's own repository.
EOF
	exit 1
fi
if [[ -z "$TEMPLATE_REF" ]]; then
	TEMPLATE_REF="main"
	TEMPLATE_REF_SRC="default"
fi

detect_ref_kind() {
	local ref="$1" repo="$2"
	if [[ "$ref" == refs/tags/* ]]; then
		echo tag; return
	fi
	if [[ "$ref" == refs/heads/* ]]; then
		echo branch; return
	fi
	if [[ -d "$repo/.git" ]]; then
		if git -C "$repo" show-ref --verify --quiet "refs/tags/$ref"; then
			echo tag; return
		fi
		if git -C "$repo" show-ref --verify --quiet "refs/heads/$ref"; then
			echo branch; return
		fi
	fi
	if [[ "$ref" =~ ^[0-9a-f]{7,40}$ ]]; then
		echo revision; return
	fi
	if [[ "$ref" =~ ^v?[0-9]+(\.[0-9]+)*([-+][0-9A-Za-z.-]+)?$ ]]; then
		echo tag; return
	fi
	echo branch
}

REF_KIND="$(detect_ref_kind "$TEMPLATE_REF" "$TEMPLATE_REPO_URL")"
case "$REF_KIND" in
	tag) REF_FLAG="--tag"; REF_FLAG_NAME="tag" ;;
	revision) REF_FLAG="--revision"; REF_FLAG_NAME="revision" ;;
	*) REF_KIND="branch"; REF_FLAG="--branch"; REF_FLAG_NAME="branch" ;;
esac

# ---------------------------------------------------------------------------
# Opt-in cluster probe (read-only)
#
# Nothing in this section runs unless --probe-cluster was passed. Only `get`,
# `api-resources` and `cluster-info` are ever invoked: no mutating verbs, no
# secret reads, and every failure degrades to repository detection.
# ---------------------------------------------------------------------------

CNPG_CLUSTER_NAME=""
CNPG_CLUSTER_NS=""
CNPG_CLUSTER_READY=""
CNPG_CLUSTER_SRC="default"
CNPG_DATABASE_CRD="unknown"
CNPG_API_SRC="default"
CNPG_POOLER_NAME=""
CNPG_POOLER_SRC="default"
KAFKA_CLUSTER_BROKER=""
KAFKA_CLUSTER_SRC="default"
KAFKA_OPERATOR="none"
KAFKA_OPERATOR_SRC="default"
REDPANDA_CRD=false
REDPANDA_CLUSTER=""
REDPANDA_SRC="default"
STRIMZI_CRD=false
STRIMZI_KAFKA=""
STRIMZI_SRC="default"

repo_ns_match() {
	local ns="$1"
	[[ -n "$ns" ]] || return 1
	[[ "$ns" == "$NS_DEV" || "$ns" == "$NS_STAGING" || "$ns" == "$NS_PROD" ]]
}

probe_kubectl() {
	local out=""
	out="$(kubectl "$@" 2>/dev/null)" || return 1
	printf '%s' "$out"
}

probe_api_resources() {
	local out=""
	if ! out="$(probe_kubectl api-resources)"; then
		warn "cluster probe: api-resources are not readable; CRD detection skipped"
		return 0
	fi
	CNPG_API_SRC="cluster"
	if printf '%s\n' "$out" | grep -qE '(^|[[:space:]])databases\.postgresql\.cnpg\.io([[:space:]]|$)'; then
		CNPG_DATABASE_CRD=true
	else
		CNPG_DATABASE_CRD=false
	fi
	if printf '%s\n' "$out" | grep -qE '(^|[[:space:]])redpandas\.cluster\.redpanda\.com([[:space:]]|$)'; then
		REDPANDA_CRD=true
	fi
	if printf '%s\n' "$out" | grep -qE '(^|[[:space:]])kafkas\.kafka\.strimzi\.io([[:space:]]|$)'; then
		STRIMZI_CRD=true
	fi
}

probe_cnpg() {
	local json="" lines="" ns="" name="" ready=""
	local total=0 repo_count=0
	local only_ns="" only_name="" only_ready=""
	local cand_ns="" cand_name="" cand_ready=""
	if ! json="$(probe_kubectl get clusters.postgresql.cnpg.io -A -o json)"; then
		warn "cluster probe: CNPG clusters are not readable; keeping repository detection"
		return 0
	fi
	lines="$(printf '%s' "$json" | yq e '.items[]? | (.metadata.namespace // "") + "\t" + (.metadata.name // "") + "\t" + ((.status.readyInstances // 0) | tostring)' - 2>/dev/null || true)"
	while IFS=$'\t' read -r ns name ready; do
		[[ -n "$name" ]] || continue
		total=$((total + 1))
		only_ns="$ns"; only_name="$name"; only_ready="$ready"
		if repo_ns_match "$ns"; then
			repo_count=$((repo_count + 1))
			cand_ns="$ns"; cand_name="$name"; cand_ready="$ready"
		fi
	done <<< "$lines"
	local sel_ns="" sel_name="" sel_ready=""
	if (( repo_count == 1 )); then
		sel_ns="$cand_ns"; sel_name="$cand_name"; sel_ready="$cand_ready"
	elif (( repo_count == 0 && total == 1 )); then
		sel_ns="$only_ns"; sel_name="$only_name"; sel_ready="$only_ready"
	elif (( repo_count > 1 )); then
		warn "cluster probe: multiple CNPG clusters in repository namespaces; keeping repository detection"
		return 0
	elif (( total > 1 )); then
		warn "cluster probe: no CNPG cluster in repository namespaces ($NS_DEV/$NS_STAGING/$NS_PROD); keeping repository detection"
		return 0
	else
		return 0
	fi
	CNPG_CLUSTER_NAME="$sel_name"
	CNPG_CLUSTER_NS="$sel_ns"
	CNPG_CLUSTER_READY="$sel_ready"
	CNPG_CLUSTER_SRC="cluster"
	if [[ "$PG_CLUSTER_PRESENT" == true && "$CNPG_CLUSTER_NAME" != "$PG_CLUSTER" ]]; then
		warn "cluster probe: CNPG cluster '$CNPG_CLUSTER_NAME' ($CNPG_CLUSTER_NS) does not match repository cluster '$PG_CLUSTER'; keeping repository value"
		return 0
	fi
	PG_CLUSTER="$CNPG_CLUSTER_NAME"
	PG_CLUSTER_SRC="cluster"
}

probe_poolers() {
	local json="" lines="" ns="" name=""
	local total=0 ns_matches=0 name_matches=0
	local sel_ns="" sel_name="" cand_ns="" cand_name=""
	local only_ns="" only_name=""
	local target_ns="${CNPG_CLUSTER_NS:-}"
	if ! json="$(probe_kubectl get poolers.postgresql.cnpg.io -A -o json)"; then
		warn "cluster probe: CNPG poolers are not readable; keeping repository detection"
		return 0
	fi
	lines="$(printf '%s' "$json" | yq e '.items[]? | (.metadata.namespace // "") + "\t" + (.metadata.name // "")' - 2>/dev/null || true)"
	while IFS=$'\t' read -r ns name; do
		[[ -n "$name" ]] || continue
		total=$((total + 1))
		only_ns="$ns"; only_name="$name"
		if [[ -n "$PG_POOLER_HOST" && "$name" == "$PG_POOLER_HOST" ]]; then
			name_matches=$((name_matches + 1))
			sel_ns="$ns"; sel_name="$name"
		fi
		if [[ -n "$target_ns" && "$ns" == "$target_ns" ]]; then
			ns_matches=$((ns_matches + 1))
			cand_ns="$ns"; cand_name="$name"
		fi
	done <<< "$lines"
	if (( name_matches == 1 )); then
		:
	elif (( ns_matches == 1 )); then
		sel_ns="$cand_ns"; sel_name="$cand_name"
	elif (( total == 1 )); then
		sel_ns="$only_ns"; sel_name="$only_name"
	elif (( total > 1 )); then
		warn "cluster probe: multiple CNPG poolers are ambiguous; keeping repository detection"
		return 0
	else
		return 0
	fi
	[[ -n "$sel_name" ]] || return 0
	CNPG_POOLER_NAME="$sel_name"
	CNPG_POOLER_SRC="cluster"
	if [[ -n "$PG_POOLER_HOST" && "$CNPG_POOLER_NAME" != "$PG_POOLER_HOST" ]]; then
		warn "cluster probe: CNPG pooler '$CNPG_POOLER_NAME' ($sel_ns) does not match repository pooler '$PG_POOLER_HOST'; keeping repository value"
		return 0
	fi
	PG_POOLER_HOST="$CNPG_POOLER_NAME"
	PG_POOLER_SRC="cluster"
}

probe_brokers() {
	local json="" lines="" ns="" name="" port=""
	local repo_ns="" repo_svc=""
	local host="${KAFKA_BROKER%%:*}"
	if [[ -n "$KAFKA_BROKER" && "$KAFKA_BROKER" == *:* ]]; then
		if [[ "$host" =~ ^([^.]+)\.([^.]+)\.svc(\.|$) ]]; then
			repo_svc="${BASH_REMATCH[1]}"
			repo_ns="${BASH_REMATCH[2]}"
		fi
	fi
	if ! json="$(probe_kubectl get svc -A -o json)"; then
		warn "cluster probe: services are not readable; keeping repository detection"
		return 0
	fi
	lines="$(printf '%s' "$json" | yq e '.items[]? | select((.metadata.name // "") | downcase | test("kafka|redpanda")) | . as $s | ($s.spec.ports // [])[]? | select(.port == 9092 or .port == 9093) | (($s.metadata.namespace // "") + "\t" + ($s.metadata.name // "") + "\t" + (.port | tostring))' - 2>/dev/null || true)"
	declare -A broker_port=()
	local key=""
	while IFS=$'\t' read -r ns name port; do
		[[ -n "$name" && -n "$port" ]] || continue
		key="$ns/$name"
		if [[ -z "${broker_port[$key]:-}" || "$port" == "9092" ]]; then
			broker_port["$key"]="$port"
		fi
	done <<< "$lines"
	local candidates=() repo_ns_candidates=() repo_match=()
	local candidate=""
	for key in "${!broker_port[@]}"; do
		ns="${key%%/*}"; name="${key#*/}"; port="${broker_port[$key]}"
		candidate="$ns"$'\t'"$name"$'\t'"$port"
		candidates+=("$candidate")
		if [[ -n "$repo_ns" && "$ns" == "$repo_ns" ]]; then
			repo_ns_candidates+=("$candidate")
			if [[ -n "$repo_svc" && "$name" == "$repo_svc" ]]; then
				repo_match+=("$candidate")
			fi
		fi
	done
	local sel_ns="" sel_name="" sel_port="" sel_in_repo=0
	if (( ${#repo_match[@]} == 1 )); then
		IFS=$'\t' read -r sel_ns sel_name sel_port <<< "${repo_match[0]}"
		sel_in_repo=1
	elif (( ${#repo_ns_candidates[@]} == 1 )); then
		IFS=$'\t' read -r sel_ns sel_name sel_port <<< "${repo_ns_candidates[0]}"
		sel_in_repo=1
	elif (( ${#candidates[@]} == 1 )); then
		IFS=$'\t' read -r sel_ns sel_name sel_port <<< "${candidates[0]}"
	elif (( ${#candidates[@]} > 1 )); then
		warn "cluster probe: multiple Kafka/Redpanda brokers are ambiguous; keeping repository detection"
		return 0
	else
		return 0
	fi
	KAFKA_CLUSTER_BROKER="$sel_name.$sel_ns.svc.cluster.local:$sel_port"
	KAFKA_CLUSTER_SRC="cluster"
	if [[ "$KAFKA_BROKER_SRC" == "override" ]]; then
		warn "cluster probe: broker '$KAFKA_CLUSTER_BROKER' not merged because --kafka-broker was passed explicitly"
		return 0
	fi
	if (( sel_in_repo == 0 )) && [[ -n "$KAFKA_BROKER" ]]; then
		warn "cluster probe: only broker '$KAFKA_CLUSTER_BROKER' is outside repository namespace '${repo_ns:-<none>}'; keeping repository value"
		return 0
	fi
	KAFKA_BROKER="$KAFKA_CLUSTER_BROKER"
	KAFKA_BROKER_SRC="cluster"
	KAFKA_DEV="$KAFKA_BROKER"
	KAFKA_DEV_SRC="cluster"
	if [[ "$KAFKA_STAGING_SRC" == "default" ]]; then
		KAFKA_STAGING="$KAFKA_BROKER"
		KAFKA_STAGING_SRC="cluster"
	fi
	if [[ "$KAFKA_PROD_SRC" == "default" ]]; then
		KAFKA_PROD="$KAFKA_BROKER"
		KAFKA_PROD_SRC="cluster"
	fi
}

probe_kafka_operators() {
	local json="" lines="" ns="" name=""
	local found_redpanda="" found_strimzi=""
	local check_redpanda=0 check_strimzi=0
	[[ "$REDPANDA_CRD" == true || "$CNPG_API_SRC" != "cluster" ]] && check_redpanda=1
	[[ "$STRIMZI_CRD" == true || "$CNPG_API_SRC" != "cluster" ]] && check_strimzi=1
	if (( check_redpanda == 1 )); then
		if json="$(probe_kubectl get redpandas.cluster.redpanda.com -A -o json)"; then
			lines="$(printf '%s' "$json" | yq e '.items[]? | (.metadata.namespace // "") + "\t" + (.metadata.name // "")' - 2>/dev/null || true)"
			while IFS=$'\t' read -r ns name; do
				[[ -n "$name" ]] || continue
				found_redpanda="${found_redpanda:+$found_redpanda, }$name/$ns"
			done <<< "$lines"
		else
			warn "cluster probe: Redpanda clusters are not readable; keeping repository detection"
		fi
	fi
	if (( check_strimzi == 1 )); then
		if json="$(probe_kubectl get kafkas.kafka.strimzi.io -A -o json)"; then
			lines="$(printf '%s' "$json" | yq e '.items[]? | (.metadata.namespace // "") + "\t" + (.metadata.name // "")' - 2>/dev/null || true)"
			while IFS=$'\t' read -r ns name; do
				[[ -n "$name" ]] || continue
				found_strimzi="${found_strimzi:+$found_strimzi, }$name/$ns"
			done <<< "$lines"
		else
			warn "cluster probe: Strimzi Kafka clusters are not readable; keeping repository detection"
		fi
	fi
	REDPANDA_CLUSTER="${found_redpanda:-<none>}"
	[[ -n "$found_redpanda" ]] && REDPANDA_SRC="cluster"
	STRIMZI_KAFKA="${found_strimzi:-<none>}"
	[[ -n "$found_strimzi" ]] && STRIMZI_SRC="cluster"
	if [[ -n "$found_redpanda" || -n "$found_strimzi" ]]; then
		KAFKA_OPERATOR=""
		[[ -n "$found_redpanda" ]] && KAFKA_OPERATOR="redpanda"
		[[ -n "$found_strimzi" ]] && KAFKA_OPERATOR="${KAFKA_OPERATOR:+$KAFKA_OPERATOR+}strimzi"
		KAFKA_OPERATOR_SRC="cluster"
	fi
}

run_cluster_probe() {
	if ! command -v kubectl >/dev/null 2>&1; then
		warn "cluster probe requested but kubectl was not found; using repository detection only"
		return 0
	fi
	probe_api_resources
	probe_cnpg
	if [[ -n "$CNPG_CLUSTER_NAME" ]]; then
		probe_poolers
	fi
	probe_brokers
	probe_kafka_operators
}

if (( PROBE_CLUSTER == 1 )); then
	run_cluster_probe
fi

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

SLUG="$NAME"
if [[ ! "$SLUG" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ ]]; then
	cat >&2 <<EOF
Error: invalid service name '$NAME'.

service_slug must be kebab-case: start with a lowercase letter, use only
lowercase letters, digits and single hyphens, and end with a letter or digit
(regex: ^[a-z]([a-z0-9-]*[a-z0-9])?\$). Example: orders-api.
EOF
	exit 1
fi
if (( ${#SLUG} > 63 )); then
	echo "Error: service slug '$SLUG' is ${#SLUG} bytes; Kubernetes DNS labels allow at most 63" >&2
	exit 1
fi

if [[ -n "$PROJECT_SLUG" && "$SLUG" == "$PROJECT_SLUG" ]]; then
	echo "Error: service slug '$SLUG' is the platform project slug; pick a different name" >&2
	exit 1
fi

while IFS= read -r _pkg; do
	[[ -n "$_pkg" ]] || continue
	_pkg_norm="$(printf '%s' "$_pkg" | tr '[:upper:]_' '[:lower:]-')"
	if [[ "$SLUG" == "$_pkg_norm" ]]; then
		echo "Error: service slug '$SLUG' collides with workspace package '$_pkg'" >&2
		exit 1
	fi
	if [[ "$_pkg_norm" == axum-cloudevents* ]]; then
		if [[ "$SLUG" == "$_pkg_norm" ]]; then
			echo "Error: service slug '$SLUG' collides with vendored crate '$_pkg'" >&2
			exit 1
		fi
	fi
	if [[ "$_pkg_norm" == "service-core" && "$SLUG" == "service-core" ]]; then
		echo "Error: service slug 'service-core' is reserved for the shared crate" >&2
		exit 1
	fi
done < <(workspace_packages)

DB_NAME="${SLUG//-/_}"
if [[ ! "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]] || (( ${#DB_NAME} > 63 )); then
	echo "Error: computed database name '$DB_NAME' is not PostgreSQL-safe (<=63 bytes, letters/digits/underscore)" >&2
	exit 1
fi
case "$DB_NAME" in
	app|postgres|template0|template1)
		echo "Error: computed database name '$DB_NAME' is reserved by PostgreSQL; choose another service name" >&2
		exit 1 ;;
esac

TARGET_DIR="$ROOT/services/$SLUG"
if [[ -e "$TARGET_DIR" && ! -d "$TARGET_DIR" ]]; then
	echo "Error: services/$SLUG exists and is not a directory" >&2
	exit 1
fi
if [[ -d "$TARGET_DIR" ]] && [[ -n "$(ls -A "$TARGET_DIR" 2>/dev/null)" ]]; then
	if (( FORCE == 0 )); then
		echo "Error: services/$SLUG is not empty; pass --force only for a deliberate overwrite" >&2
		exit 1
	fi
	warn "services/$SLUG is not empty; --force requested an explicit overwrite"
fi

# ---------------------------------------------------------------------------
# Effective options (detected defaults + explicit flags + safety forced-offs)
# ---------------------------------------------------------------------------

INCLUDE_POSTGRES=false
[[ "$PG_CLUSTER_PRESENT" == true ]] && INCLUDE_POSTGRES=true
[[ -n "$POSTGRES_SET" ]] && INCLUDE_POSTGRES="$POSTGRES_SET"

INCLUDE_S3=false
[[ "$APP_DATA_CLAIM" == true ]] && INCLUDE_S3=true
[[ -n "$S3_SET" ]] && INCLUDE_S3="$S3_SET"

KAFKA_PUBLISH=false
[[ -n "$KAFKA_PUBLISH_SET" ]] && KAFKA_PUBLISH="$KAFKA_PUBLISH_SET"
KAFKA_SOURCE=false
[[ -n "$KAFKA_SOURCE_SET" ]] && KAFKA_SOURCE="$KAFKA_SOURCE_SET"
ENABLE_FLAGGER=false
[[ -n "$FLAGGER_SET" ]] && ENABLE_FLAGGER="$FLAGGER_SET"

WORKLOAD_DEPLOYMENT=false
[[ "$WORKLOAD" == "deployment" ]] && WORKLOAD_DEPLOYMENT=true

if [[ -n "$KAFKA_BROKER_OVERRIDE" && ! "$KAFKA_BROKER_OVERRIDE" =~ ^[A-Za-z0-9._-]+:[0-9]+$ ]]; then
	echo "Error: --kafka-broker must be <host:port> (got '$KAFKA_BROKER_OVERRIDE')" >&2
	exit 1
fi

if [[ "$INCLUDE_POSTGRES" == true && "$PG_CLUSTER_PRESENT" != true ]]; then
	echo "Error: --postgres requested but no CloudNativePG Cluster was detected" >&2
	echo "Enable feature_postgres in the platform project or pass --no-postgres." >&2
	exit 1
fi
if [[ "$INCLUDE_POSTGRES" == true && "$CNPG_OPERATOR" != true ]]; then
	echo "Error: --postgres requested but the CNPG operator manifests were not detected" >&2
	exit 1
fi
if [[ "$INCLUDE_S3" == true && "$APP_DATA_CLAIM" != true ]]; then
	echo "Error: --s3 requested but the project-level app-data claim was not detected" >&2
	echo "Enable feature_s3 in the platform project or pass --no-s3." >&2
	exit 1
fi
if [[ "$KAFKA_PUBLISH" == true || "$KAFKA_SOURCE" == true ]]; then
	if [[ -z "$KAFKA_BROKER" ]]; then
		echo "Error: Kafka was requested but no broker was detected" >&2
		echo "Pass --kafka-broker <host:port> or set KAFKA_BROKER_URL." >&2
		exit 1
	fi
fi
if [[ "$WORKLOAD_DEPLOYMENT" == true && "$KAFKA_SOURCE" == true ]]; then
	KAFKA_SOURCE=false
	warn "kafka_source forced off: a KafkaSource sink is Knative-only and the pinned chart rejects a Deployment sink"
fi
if [[ "$WORKLOAD_DEPLOYMENT" == true && "$ENABLE_FLAGGER" == true ]]; then
	ENABLE_FLAGGER=false
	warn "enable_flagger forced off: Flagger canary promotion is Knative-only in this template"
fi
if [[ "$ENABLE_FLAGGER" == true && "$FLAGGER_OPERATOR" != true ]]; then
	echo "Error: --enable-flagger requested but no Flagger operator manifests were detected" >&2
	echo "Enable feature_flagger in the platform project or pass --no-flagger." >&2
	exit 1
fi

KAFKA_TOPIC="${SLUG}-events"
KAFKA_CONSUMER_GROUP="${SLUG}-consumers"

TOPIC_EXISTS=false
if [[ -n "$(yq_get "select(.kind == \"HelmRelease\") | .spec.values.kafka.sources.\"$KAFKA_TOPIC\"" "$BASE_HR")" ]]; then
	TOPIC_EXISTS=true
fi

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

_emit_repo=0
_emit_default=0
_emit_override=0
_emit_cluster=0
_emit_explicit=0

emit() {
	local key="$1" value="$2" source="$3"
	case "$source" in
		repo) _emit_repo=$((_emit_repo + 1)) ;;
		default|detected-default) _emit_default=$((_emit_default + 1)) ;;
		override) _emit_override=$((_emit_override + 1)) ;;
		cluster) _emit_cluster=$((_emit_cluster + 1)) ;;
		*) _emit_explicit=$((_emit_explicit + 1)) ;;
	esac
	printf '%-30s = %-58s [%s]\n' "$key" "$value" "$source"
}

if (( PROBE_CLUSTER == 1 )); then
	echo "add-service detection (repository manifests + opt-in read-only cluster probe)"
else
	echo "add-service detection (repository manifests only; no cluster access)"
fi
echo "Project root: $ROOT"
echo

echo "== Repository facts =="
emit project_slug "$PROJECT_SLUG" "repo"
emit image_registry "$IMAGE_REGISTRY" "repo"
emit github_org "$GITHUB_ORG" "repo"
emit image_repository "$IMAGE_REPO" "repo"
emit target_namespace_dev "$NS_DEV" "repo"
emit target_namespace_staging "$NS_STAGING" "repo"
emit target_namespace_prod "$NS_PROD" "repo"
emit pg_cluster "$PG_CLUSTER" "$PG_CLUSTER_SRC"
emit pg_app_secret "$PG_APP_SECRET" "$PG_APP_SECRET_SRC"
emit pg_ca_secret "$PG_CA_SECRET" "$PG_CA_SECRET_SRC"
emit pg_pooler_host "${PG_POOLER_HOST:-<none>}" "$PG_POOLER_SRC"
emit redis_url "$REDIS_URL" "$REDIS_SRC"
emit otel_endpoint "$OTEL_ENDPOINT" "$OTEL_SRC"
emit kafka_bootstrap_servers "${KAFKA_DEV:-<none>}" "$KAFKA_DEV_SRC"
emit kafka_bootstrap_servers_staging "${KAFKA_STAGING:-<none>}" "$KAFKA_STAGING_SRC"
emit kafka_bootstrap_servers_prod "${KAFKA_PROD:-<none>}" "$KAFKA_PROD_SRC"
emit canary_prometheus_url_dev "$CANARY_DEV" "$CANARY_DEV_SRC"
emit canary_prometheus_url_staging "$CANARY_STAGING" "$CANARY_STAGING_SRC"
emit canary_prometheus_url_prod "$CANARY_PROD" "$CANARY_PROD_SRC"
emit template_repo_url "$TEMPLATE_REPO_URL" "$TEMPLATE_URL_SRC"
emit template_ref "$TEMPLATE_REF" "$TEMPLATE_REF_SRC"
echo

echo "== Detected capabilities =="
emit cnpg_operator "$CNPG_OPERATOR" "repo"
emit postgres_cluster_present "$PG_CLUSTER_PRESENT" "repo"
emit postgres_pooler_present "$([[ -f "$PG_POOLER_FILE" ]] && echo true || echo false)" "repo"
emit app_data_claim_present "$APP_DATA_CLAIM" "repo"
emit s3_storage_class "$S3_STORAGE_CLASS" "$S3_SOURCE"
emit kafka_source_present "$KAFKA_SOURCE_PRESENT" "repo"
emit image_updates_enabled "$IMAGE_UPDATES" "repo"
emit flagger_operator_present "$FLAGGER_OPERATOR" "repo"
echo

if (( PROBE_CLUSTER == 1 )); then
	echo "== Cluster probe (opt-in, read-only) =="
	emit cnpg_cluster "${CNPG_CLUSTER_NAME:-<none>}" "$CNPG_CLUSTER_SRC"
	emit cnpg_cluster_namespace "${CNPG_CLUSTER_NS:-<none>}" "$CNPG_CLUSTER_SRC"
	emit cnpg_cluster_ready_instances "${CNPG_CLUSTER_READY:-<unknown>}" "$CNPG_CLUSTER_SRC"
	emit cnpg_database_crd "$CNPG_DATABASE_CRD" "$CNPG_API_SRC"
	emit cnpg_pooler "${CNPG_POOLER_NAME:-<none>}" "$CNPG_POOLER_SRC"
	emit kafka_broker_cluster "${KAFKA_CLUSTER_BROKER:-<none>}" "$KAFKA_CLUSTER_SRC"
	emit kafka_operator "$KAFKA_OPERATOR" "$KAFKA_OPERATOR_SRC"
	emit redpanda_cluster "$REDPANDA_CLUSTER" "$REDPANDA_SRC"
	emit strimzi_kafka_cluster "$STRIMZI_KAFKA" "$STRIMZI_SRC"
	echo "redis/s3/otel: repository detection only (never probed)"
	echo
fi

echo "== Service defaults =="
emit service_slug "$SLUG" "cli"
emit db_name "$DB_NAME" "derived"
emit workload_deployment "$WORKLOAD_DEPLOYMENT" "cli"
emit include_postgres "$INCLUDE_POSTGRES" "$([[ -n "$POSTGRES_SET" ]] && echo cli || echo detected-default)"
emit include_s3 "$INCLUDE_S3" "$([[ -n "$S3_SET" ]] && echo cli || echo detected-default)"
emit kafka_publish "$KAFKA_PUBLISH" "$([[ -n "$KAFKA_PUBLISH_SET" ]] && echo cli || echo default)"
emit kafka_source "$KAFKA_SOURCE" "$([[ -n "$KAFKA_SOURCE_SET" ]] && echo cli || echo default)"
emit enable_flagger "$ENABLE_FLAGGER" "$([[ -n "$FLAGGER_SET" ]] && echo cli || echo default)"
emit enable_image_updates "$IMAGE_UPDATES" "repo"
emit kafka_topic "$KAFKA_TOPIC" "derived"
emit kafka_consumer_group "$KAFKA_CONSUMER_GROUP" "derived"
echo

echo "== Provenance summary =="
if (( PROBE_CLUSTER == 1 )); then
	printf 'repo=%d defaulted=%d override=%d cluster=%d cli/derived=%d\n' \
		"$_emit_repo" "$_emit_default" "$_emit_override" "$_emit_cluster" "$_emit_explicit"
else
	printf 'repo=%d defaulted=%d override=%d cli/derived=%d\n' \
		"$_emit_repo" "$_emit_default" "$_emit_override" "$_emit_explicit"
fi
echo

echo "== Template ref =="
emit template_ref_kind "$REF_KIND" "derived"
emit cargo_generate_ref_flag "$REF_FLAG $TEMPLATE_REF" "derived"
echo

echo "== Planned cargo-generate command =="
if [[ -d "$TEMPLATE_REPO_URL" ]]; then
	printf 'cargo generate --path %q service-template' "$TEMPLATE_REPO_URL"
else
	printf 'cargo generate --git %q service-template' "$TEMPLATE_REPO_URL"
fi
printf ' --name %q --init --template-values-file %q --destination %q %s %q\n' \
	"$SLUG" "/tmp/${SLUG}-service-values.toml" "services/$SLUG" "$REF_FLAG" "$TEMPLATE_REF"
echo

echo "== Planned registration edits =="
for _env in dev staging prod; do
	_overlay="$OVERLAYS/$_env/kustomization.yaml"
	_line="  - ../../../services/$SLUG/deploy/overlays/$_env"
	if [[ -f "$_overlay" ]] && grep -qF "services/$SLUG/deploy/overlays/$_env" "$_overlay"; then
		echo "$_overlay: already registered ($_line)"
	else
		echo "$_overlay: resources += $_line"
	fi
done
if [[ "$IMAGE_UPDATES" == true ]]; then
	for _env in dev staging prod; do
		echo "deploy/flux/config/$_env/kustomization.yaml: add ImageRepository/ImagePolicy for ${PROJECT_SLUG}-${SLUG} (image updates enabled)"
	done
fi
echo

echo "== Kafka topic next step =="
if [[ "$KAFKA_PUBLISH" != true && "$KAFKA_SOURCE" != true ]]; then
	echo "Kafka is disabled for this service; no topic needs to be created."
elif [[ "$TOPIC_EXISTS" == true ]]; then
	echo "Topic '$KAFKA_TOPIC' already appears in the local manifests; review partitioning/retention before reuse."
elif [[ -n "$KAFKA_BROKER" ]]; then
	cat <<EOF
Topic '$KAFKA_TOPIC' was not found in the local manifests. The broker may not
auto-create topics; create it explicitly, for example:
  kafka-topics --bootstrap-server $KAFKA_BROKER --create \\
    --topic $KAFKA_TOPIC --partitions 3 --replication-factor 1
EOF
else
	echo "No Kafka broker detected; set --kafka-broker before creating the topic '$KAFKA_TOPIC'."
fi
echo

toml_q() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

toml_str() {
	printf '%s = "%s"\n' "$1" "$(toml_q "$2")"
}

generate_and_register() {
	local values_file overlay config line env file path
	values_file="$(mktemp "/tmp/${SLUG}-service-values-XXXXXX.toml")"
	trap 'rm -f "${values_file:-}"' EXIT

	{
		printf '[values]\n'
		toml_str service_slug "$SLUG"
		toml_str db_name "$DB_NAME"
		toml_str project_slug "$PROJECT_SLUG"
		toml_str image_registry "$IMAGE_REGISTRY"
		toml_str github_org "$GITHUB_ORG"
		printf 'include_postgres = %s\n' "$INCLUDE_POSTGRES"
		printf 'include_s3 = %s\n' "$INCLUDE_S3"
		printf 'kafka_publish = %s\n' "$KAFKA_PUBLISH"
		printf 'kafka_source = %s\n' "$KAFKA_SOURCE"
		printf 'workload_deployment = %s\n' "$WORKLOAD_DEPLOYMENT"
		printf 'enable_flagger = %s\n' "$ENABLE_FLAGGER"
		printf 'enable_image_updates = %s\n' "$IMAGE_UPDATES"
		toml_str target_namespace_dev "$NS_DEV"
		toml_str target_namespace_staging "$NS_STAGING"
		toml_str target_namespace_prod "$NS_PROD"
		toml_str pg_cluster "$PG_CLUSTER"
		toml_str pg_app_secret "$PG_APP_SECRET"
		toml_str pg_ca_secret "$PG_CA_SECRET"
		toml_str pg_pooler_host "$PG_POOLER_HOST"
		toml_str redis_url "$REDIS_URL"
		toml_str otel_endpoint "$OTEL_ENDPOINT"
		toml_str kafka_bootstrap_servers "${KAFKA_DEV:-kafka.kafka.svc.cluster.local:9092}"
		toml_str kafka_bootstrap_servers_staging "${KAFKA_STAGING:-kafka.staging.svc.cluster.local:9092}"
		toml_str kafka_bootstrap_servers_prod "${KAFKA_PROD:-kafka.prod.svc.cluster.local:9092}"
		toml_str kafka_topic "$KAFKA_TOPIC"
		toml_str kafka_consumer_group "$KAFKA_CONSUMER_GROUP"
		toml_str canary_prometheus_url_dev "$CANARY_DEV"
		toml_str canary_prometheus_url_staging "$CANARY_STAGING"
		toml_str canary_prometheus_url_prod "$CANARY_PROD"
	} > "$values_file"

	if [[ -e "$TARGET_DIR" && -n "$(ls -A "$TARGET_DIR" 2>/dev/null)" ]]; then
		if (( FORCE == 1 )); then
			warn "removing existing services/${SLUG} (--force)"
			rm -rf "$TARGET_DIR"
		else
			echo "Error: services/${SLUG} is not empty; pass --force only for a deliberate overwrite" >&2
			return 1
		fi
	fi
	mkdir -p "$TARGET_DIR"

	echo "== Generating services/${SLUG} (workload: $([[ "$WORKLOAD_DEPLOYMENT" == true ]] && echo Deployment || echo Knative)) =="
	if [[ -f "${TEMPLATE_REPO_URL}/service-template/cargo-generate.toml" ]]; then
		( cd "$ROOT" && cargo generate --path "${TEMPLATE_REPO_URL}" service-template \
			--name "$SLUG" --init --template-values-file "$values_file" \
			--destination "services/$SLUG" ) || return 1
	elif [[ -f "${TEMPLATE_REPO_URL}/cargo-generate.toml" ]]; then
		( cd "$ROOT" && cargo generate --path "${TEMPLATE_REPO_URL}" \
			--name "$SLUG" --init --template-values-file "$values_file" \
			--destination "services/$SLUG" ) || return 1
	else
		( cd "$ROOT" && cargo generate --git "${TEMPLATE_REPO_URL}" service-template \
			--name "$SLUG" --init --template-values-file "$values_file" \
			"$REF_FLAG" "$TEMPLATE_REF" --destination "services/$SLUG" ) || return 1
	fi

	if [[ -d "${TARGET_DIR}/.git" ]]; then
		echo "Error: generated service contains a nested .git directory" >&2
		return 1
	fi

	python3 - "$ROOT/Cargo.toml" "services/$SLUG" <<'PYWORKSPACE'
import re
import sys

path, member = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
if f'"{member}"' in text or f"'{member}'" in text:
    print(f"workspace member already present: {member}")
    sys.exit(0)
match = re.search(r"(?ms)^members\s*=\s*\[(.*?)\]", text)
if not match:
    raise SystemExit(f"Error: [workspace].members not found in {path}")
body = match.group(1).rstrip()
if body and not body.endswith(","):
    body += ","
body += f'\n  "{member}",\n'
open(path, "w", encoding="utf-8").write(
    text[: match.start(1)] + body + text[match.end(1):]
)
print(f"workspace member added: {member}")
PYWORKSPACE

	for env in dev staging prod; do
		overlay="${OVERLAYS}/${env}/kustomization.yaml"
		if [[ ! -f "$overlay" ]]; then
			echo "Error: missing environment overlay: $overlay" >&2
			return 1
		fi
		line="  - ../../../services/${SLUG}/deploy/overlays/${env}"
		if grep -qF "services/${SLUG}/deploy/overlays/${env}" "$overlay"; then
			echo "$overlay: already registered"
			continue
		fi
		python3 - "$overlay" "$line" <<'PYOVERLAY'
import re
import sys

path, line = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
match = re.search(r"(?m)^resources:\s*$", text)
if not match:
    raise SystemExit(f"Error: resources: not found in {path}")
text = text[: match.end()] + "\n" + line + text[match.end():]
open(path, "w", encoding="utf-8").write(text)
print(f"{path}: registered {line.strip()}")
PYOVERLAY
	done

	if [[ "$IMAGE_UPDATES" == true ]]; then
		for env in dev staging prod; do
			config="${ROOT}/deploy/flux/config/${env}/kustomization.yaml"
			[[ -f "$config" ]] || continue
			for file in flux-image-repository.yaml flux-image-policy.yaml; do
				path="../../../services/${SLUG}/deploy/flux/${file}"
				if grep -qF "$path" "$config"; then
					continue
				fi
				python3 - "$config" "  - ${path}" <<'PYFLUX'
import re
import sys

path, line = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
match = re.search(r"(?m)^resources:\s*$", text)
if not match:
    raise SystemExit(f"Error: resources: not found in {path}")
text = text[: match.end()] + "\n" + line + text[match.end():]
open(path, "w", encoding="utf-8").write(text)
print(f"{path}: registered {line.strip()}")
PYFLUX
			done
		done
	fi

	if command -v cargo >/dev/null 2>&1; then
		if ! ( cd "$ROOT" && cargo metadata --no-deps --format-version 1 >/dev/null ); then
			echo "Error: cargo metadata failed after registration; inspect $ROOT/Cargo.toml and the new service manifest" >&2
			return 1
		fi
	fi

	rm -f "$values_file"
	trap - EXIT

	echo
	echo "✓ Service '${SLUG}' generated at services/${SLUG}"
	echo "  Workload: $([[ "$WORKLOAD_DEPLOYMENT" == true ]] && echo Deployment || echo Knative)"
	echo "  Workspace member and dev/staging/prod overlay registration updated."
	echo
	echo "Next steps:"
	echo "  1. Review services/${SLUG}/README.md and services/${SLUG}/deploy."
	echo "  2. Build the image with: make dev-restart SERVICE=${SLUG}"
	echo "  3. Commit the new service and reconcile Flux."
}

if (( DRY_RUN == 1 )); then
	echo "Dry run: no files were written and no generation was performed."
	exit 0
fi

generate_and_register
