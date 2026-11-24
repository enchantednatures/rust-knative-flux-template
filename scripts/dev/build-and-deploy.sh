#!/bin/bash
#
# Build and deploy one service to the local Kind cluster.
#
# Usage:
#   scripts/dev/build-and-deploy.sh [--service <slug>] [--deploy-only] [--dry-run]
#
# Options:
#   --service <slug>  Service to build/deploy (default: the first service).
#                     Underscores are normalized to hyphens (orders_api ->
#                     orders-api). Also readable from the SERVICE env var.
#   --deploy-only     Skip the docker build/push and render/apply the existing
#                     image. Without a kubeconfig it degrades to --dry-run.
#   --dry-run         Render the service manifests only; never touches a cluster.
#   -h, --help        Show this help.
#
# The first service keeps its historic image/tag: localhost:5001/<project>:dev.
# Added services use localhost:5001/<project>-<service>:dev (the host-facing
# alias of kind-registry-dev:5000/<project>-<service>:dev).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
KUBECONFIG_PATH="${PROJECT_ROOT}/.kubeconfig-dev"
REGISTRY_PORT="5001"

# Project names are normalized at template generation time.
# PROJECT_NAME uses hyphens (Kubernetes convention); the crate uses underscores.
PROJECT_NAME="{{ project_name | replace: "_", "-" }}"
CRATE_NAME="{{ crate_name }}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

usage() {
	sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
}

SERVICE_ARG=""
DEPLOY_ONLY=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
	case "$1" in
		--service)
			SERVICE_ARG="${2:-}"
			shift 2
			;;
		--service=*)
			SERVICE_ARG="${1#*=}"
			shift
			;;
		--deploy-only)
			DEPLOY_ONLY=true
			shift
			;;
		--dry-run|--render-only)
			DRY_RUN=true
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo -e "${RED}✗ Unknown option: $1${NC}" >&2
			usage >&2
			exit 2
			;;
	esac
done

# Canonical kebab-case service slug (Kubernetes/image names never use "_").
SERVICE="${SERVICE_ARG:-${SERVICE:-}}"
SERVICE="${SERVICE:-$PROJECT_NAME}"
SERVICE="${SERVICE//_/-}"

echo "Building and deploying application (service: ${SERVICE})..."
echo ""

# Verify Cargo.toml exists
if [[ ! -f "${PROJECT_ROOT}/Cargo.toml" ]]; then
	echo -e "${RED}✗ Error: Cargo.toml not found${NC}"
	exit 1
fi

# Verify the root crate name matches what we expect (first service only; added
# services are validated through cargo metadata below).
if [[ "${SERVICE}" == "${PROJECT_NAME}" ]]; then
	ACTUAL_CRATE=$(grep '^name = ' "${PROJECT_ROOT}/Cargo.toml" | head -1 | sed 's/name = "\(.*\)"/\1/')
	if [[ "${ACTUAL_CRATE}" != "${CRATE_NAME}" ]]; then
		echo -e "${RED}✗ Error: Crate name mismatch${NC}"
		echo "Expected: ${CRATE_NAME}"
		echo "Found: ${ACTUAL_CRATE}"
		exit 1
	fi
fi

# Resolve the selected service's directory/package/binary through cargo metadata.
LIST_SERVICES="${PROJECT_ROOT}/scripts/list-services.sh"
SERVICE_DIR=""
SERVICE_PKG=""
SERVICE_BIN=""
SERVICE_ROW=""

if [[ -f "${LIST_SERVICES}" ]]; then
	SERVICE_ROW="$(bash "${LIST_SERVICES}" --service "${SERVICE}" 2>/dev/null | head -1 || true)"
fi

if [[ -n "${SERVICE_ROW}" ]]; then
	IFS=$'\t' read -r RESOLVED_SLUG SERVICE_DIR SERVICE_PKG SERVICE_BIN <<<"${SERVICE_ROW}"
	SERVICE="${RESOLVED_SLUG}"
elif [[ "${SERVICE}" == "${PROJECT_NAME}" ]]; then
	SERVICE_DIR="."
	SERVICE_PKG="${CRATE_NAME}"
	SERVICE_BIN="${CRATE_NAME}"
elif [[ -d "${PROJECT_ROOT}/services/${SERVICE}" ]]; then
	# list-services.sh reads cargo metadata; keep a repo-only fallback for a
	# service directory that is present but not (yet) a workspace member.
	SERVICE_DIR="services/${SERVICE}"
	SERVICE_MANIFEST="${PROJECT_ROOT}/${SERVICE_DIR}/Cargo.toml"
	if [[ ! -f "${SERVICE_MANIFEST}" ]]; then
		echo -e "${RED}✗ Error: ${SERVICE_DIR}/Cargo.toml not found${NC}"
		exit 1
	fi
	SERVICE_PKG=$(sed -n 's/^name = "\(.*\)"/\1/p' "${SERVICE_MANIFEST}" | head -1)
	SERVICE_BIN=$(awk '
		/^\[\[bin\]\]/ { in_bin = 1; next }
		in_bin && /^name = "/ { gsub(/^name = "|"$/, ""); print; exit }
	' "${SERVICE_MANIFEST}")
	SERVICE_PKG="${SERVICE_PKG:-$(echo "${SERVICE}" | tr '-' '_')}"
	SERVICE_BIN="${SERVICE_BIN:-${SERVICE_PKG}}"
else
	echo -e "${RED}✗ Error: unknown service '${SERVICE}'${NC}"
	echo "Known services:"
	if [[ -f "${LIST_SERVICES}" ]]; then
		bash "${LIST_SERVICES}" | while IFS=$'\t' read -r slug dir _pkg _bin; do
			printf '  %-24s (%s)\n' "${slug}" "${dir}"
		done
	else
		echo "  ${PROJECT_NAME} (.)"
	fi
	exit 1
fi

# First service image/tag must stay exactly as before.
if [[ "${SERVICE}" == "${PROJECT_NAME}" ]]; then
	IMAGE="localhost:${REGISTRY_PORT}/${PROJECT_NAME}:dev"
else
	IMAGE="localhost:${REGISTRY_PORT}/${PROJECT_NAME}-${SERVICE}:dev"
fi

# A missing kubeconfig is only fatal when we would actually talk to a cluster.
if [[ ! -f "${KUBECONFIG_PATH}" ]]; then
	if [[ "${DEPLOY_ONLY}" == "true" || "${DRY_RUN}" == "true" ]]; then
		echo -e "${YELLOW}⚠ Kubeconfig not found at ${KUBECONFIG_PATH}; rendering only.${NC}"
		DRY_RUN=true
	else
		echo -e "${RED}✗ Error: Kubeconfig not found at ${KUBECONFIG_PATH}${NC}"
		echo "Run 'make dev-cluster' first (or use --deploy-only/--dry-run to render without a cluster)"
		exit 1
	fi
fi

if [[ "${DRY_RUN}" == "false" ]]; then
	export KUBECONFIG="${KUBECONFIG_PATH}"
fi

echo -e "${YELLOW}→${NC} Service:  ${SERVICE}"
echo -e "${YELLOW}→${NC} Directory: ${SERVICE_DIR}"
echo -e "${YELLOW}→${NC} Package:  ${SERVICE_PKG}"
echo -e "${YELLOW}→${NC} Binary:   ${SERVICE_BIN}"
echo -e "${YELLOW}→${NC} Image:    ${IMAGE}"
echo ""

# Resolve the Kellnr token for the Docker build. Prefer the environment;
# otherwise read the token from the Cargo credentials/config for `kellnr`.
KELLNR_TOKEN="${CARGO_REGISTRIES_KELLNR_TOKEN:-}"
if [[ -z "${KELLNR_TOKEN}" ]]; then
	for file in "${CARGO_HOME:-$HOME/.cargo}/credentials.toml" "${CARGO_HOME:-$HOME/.cargo}/config.toml"; do
		[[ -f "$file" ]] || continue
		KELLNR_TOKEN=$(awk '
			/^\[registries\.kellnr\]/ { in_section = 1; next }
			/^\[/ { in_section = 0 }
			in_section && /^[[:space:]]*token[[:space:]]*=/ {
				sub(/^[^"]*"/, "")
				sub(/".*$/, "")
				print
				exit
			}
		' "$file")
		[[ -n "$KELLNR_TOKEN" ]] && break
	done
fi

DOCKER_BUILD_ARGS=()
if [[ -n "${KELLNR_TOKEN}" ]]; then
	DOCKER_BUILD_ARGS+=(--secret "id=cargo_token,env=CARGO_REGISTRIES_KELLNR_TOKEN")
else
	echo -e "${YELLOW}⚠ Kellnr token not found; the Docker build may fail.${NC}"
	echo "  Run 'cargo login --registry kellnr' or export CARGO_REGISTRIES_KELLNR_TOKEN."
fi

if [[ "${DEPLOY_ONLY}" != "true" ]]; then
	echo -e "${YELLOW}→${NC} Building Docker image: ${IMAGE}"
	if ! CARGO_REGISTRIES_KELLNR_TOKEN="${KELLNR_TOKEN}" \
		docker build "${DOCKER_BUILD_ARGS[@]}" \
		--build-arg SERVICE_DIR="${SERVICE_DIR}" \
		--build-arg SERVICE_PKG="${SERVICE_PKG}" \
		--build-arg SERVICE_BIN="${SERVICE_BIN}" \
		-t "${IMAGE}" "${PROJECT_ROOT}"; then
		echo -e "${RED}✗ Error: Docker build failed${NC}"
		exit 1
	fi

	echo -e "${YELLOW}→${NC} Pushing image to local registry..."
	if ! docker push "${IMAGE}"; then
		echo -e "${RED}✗ Error: Failed to push image to registry${NC}"
		exit 1
	fi
fi

# Render and deploy via Helm chart
# In production, FluxCD reconciles the HelmRelease CR. For local dev, we render
# the chart ourselves with helm template and apply the raw workload YAML.
echo -e "${YELLOW}→${NC} Rendering Helm chart for local deployment..."

# Check dependencies
for cmd in kubectl helm yq; do
	if ! command -v "$cmd" &>/dev/null; then
		echo -e "${RED}✗ Error: ${cmd} is not installed${NC}"
		echo "Install ${cmd} to use the local dev workflow."
		exit 1
	fi
done

CHART_DIR="${PROJECT_ROOT}/deploy/chart"
# Kind-local overlay: falls back to the in-cluster RustFS (no Ceph provisioner).
OVERLAY_DIR="${PROJECT_ROOT}/deploy/dev/app-overlay"

# Build chart dependencies (pulls ksvc OCI dependency if not cached)
if [[ ! -d "${CHART_DIR}/charts" ]] || [[ ! -f "${CHART_DIR}/Chart.lock" ]]; then
	echo -e "${YELLOW}→${NC} Building Helm chart dependencies..."
	if ! helm dependency build "${CHART_DIR}"; then
		echo -e "${RED}✗ Error: Failed to build chart dependencies${NC}"
		exit 1
	fi
fi

# Render the merged HelmRelease (base + Kind dev overlay) and extract the
# selected service's values by HelmRelease metadata.name.
echo -e "${YELLOW}→${NC} Extracting values for HelmRelease '${SERVICE}' from Kind dev overlay..."
RENDERED_HR=$(kubectl kustomize "${OVERLAY_DIR}")
HR_DOC=$(printf '%s\n' "${RENDERED_HR}" | yq eval "select(.kind == \"HelmRelease\" and .metadata.name == \"${SERVICE}\")" -)

if [[ -z "${HR_DOC}" || "${HR_DOC}" == "null" ]]; then
	echo -e "${RED}✗ Error: no HelmRelease named '${SERVICE}' in ${OVERLAY_DIR}${NC}"
	echo "HelmReleases found:"
	printf '%s\n' "${RENDERED_HR}" | yq eval 'select(.kind == "HelmRelease") | .metadata.name' - 2>/dev/null | sed 's/^/  /'
	exit 1
fi

VALUES_FILE=$(mktemp /tmp/helm-values-XXXXXX.yaml)
MANIFEST_FILE=$(mktemp /tmp/helm-manifest-XXXXXX.yaml)
trap 'rm -f "${VALUES_FILE}" "${MANIFEST_FILE}"' EXIT

printf '%s\n' "${HR_DOC}" | yq eval '.spec.values' - >"${VALUES_FILE}"
HR_NAMESPACE=$(printf '%s\n' "${HR_DOC}" | yq eval '.metadata.namespace // "default"' -)
WORKLOAD_TYPE=$(yq eval '.services.app.workload.type // .workload.type // "Knative"' "${VALUES_FILE}")

NON_HR_RESOURCES=$(printf '%s\n' "${RENDERED_HR}" | yq eval 'select(.kind != "HelmRelease")' -)
if [[ "${DRY_RUN}" == "false" && -n "${NON_HR_RESOURCES}" && "${NON_HR_RESOURCES}" != "null" ]]; then
	echo -e "${YELLOW}→${NC} Applying non-chart resources (operator, etc.)..."
	printf '%s\n' "${NON_HR_RESOURCES}" | kubectl apply -f - || true
fi

# Render chart with the selected service's values.
echo -e "${YELLOW}→${NC} Rendering chart for '${SERVICE}' (workload: ${WORKLOAD_TYPE})..."
if ! helm template "${SERVICE}" "${CHART_DIR}" \
	-f "${VALUES_FILE}" \
	-n "${HR_NAMESPACE}" >"${MANIFEST_FILE}"; then
	echo -e "${RED}✗ Error: Failed to render Helm chart${NC}"
	exit 1
fi

if [[ "${DRY_RUN}" == "true" ]]; then
	echo ""
	echo -e "${GREEN}✓ Rendered '${SERVICE}' (workload: ${WORKLOAD_TYPE}); dry run, not applying${NC}"
	echo ""
	cat "${MANIFEST_FILE}"
	exit 0
fi

echo -e "${YELLOW}→${NC} Applying manifests to ${HR_NAMESPACE}..."
if ! kubectl apply -f "${MANIFEST_FILE}" -n "${HR_NAMESPACE}"; then
	echo -e "${RED}✗ Error: Failed to apply Helm chart${NC}"
	exit 1
fi

# Wait for the correct workload kind: ksvc for Knative, Deployment otherwise.
if [[ "${WORKLOAD_TYPE}" == "Deployment" ]]; then
	echo -e "${YELLOW}→${NC} Waiting for Deployment/${SERVICE} to be available..."
	if ! kubectl wait --for=condition=Available "deployment/${SERVICE}" -n "${HR_NAMESPACE}" --timeout=5m; then
		echo -e "${RED}✗ Error: Deployment/${SERVICE} failed to become available${NC}"
		echo ""
		echo "Deployment status:"
		kubectl get deployment "${SERVICE}" -n "${HR_NAMESPACE}" -o yaml
		echo ""
		echo "Pod status:"
		kubectl get pods -n "${HR_NAMESPACE}"
		echo ""
		echo "Recent logs:"
		kubectl logs -l "app.kubernetes.io/instance=${SERVICE}" -n "${HR_NAMESPACE}" --tail=50 2>/dev/null || echo "No logs available"
		exit 1
	fi
else
	echo -e "${YELLOW}→${NC} Waiting for Knative service to be ready..."
	if ! kubectl wait --for=condition=Ready "ksvc/${SERVICE}" -n "${HR_NAMESPACE}" --timeout=5m; then
		echo -e "${RED}✗ Error: Knative service failed to become ready${NC}"
		echo ""
		echo "Service status:"
		kubectl get ksvc "${SERVICE}" -n "${HR_NAMESPACE}" -o yaml
		echo ""
		echo "Pod status:"
		kubectl get pods -n "${HR_NAMESPACE}"
		echo ""
		echo "Recent logs:"
		kubectl logs -l "serving.knative.dev/service=${SERVICE}" -c user-container -n "${HR_NAMESPACE}" --tail=50 2>/dev/null || echo "No logs available"
		exit 1
	fi
fi

echo ""
echo -e "${GREEN}✓ Application '${SERVICE}' deployed successfully${NC}"
echo ""

if [[ "${WORKLOAD_TYPE}" == "Deployment" ]]; then
	echo "Deployment: ${SERVICE} (namespace: ${HR_NAMESPACE})"
	echo "Service:"
	kubectl get service "${SERVICE}" -n "${HR_NAMESPACE}" 2>/dev/null || true
	echo ""
	kubectl get deployment "${SERVICE}" -n "${HR_NAMESPACE}"
else
	# Get service URL
	SERVICE_URL=$(kubectl get ksvc "${SERVICE}" -n "${HR_NAMESPACE}" -o jsonpath='{.status.url}' 2>/dev/null || echo "")
	if [[ -n "$SERVICE_URL" ]]; then
		echo -e "Service URL: ${GREEN}${SERVICE_URL}${NC}"
	else
		echo "Service URL: (pending)"
	fi

	kubectl get ksvc "${SERVICE}" -n "${HR_NAMESPACE}"
	echo ""
fi
