#!/usr/bin/env bash
#
# Local E2E test script for template generation
# Mirrors .github/workflows/template-e2e-test.yaml
# Run this locally to debug template issues faster with local caching
#
# Usage:
#   ./scripts/test-template-e2e-local.sh [scenario]
#
# Scenarios:
#   no-s3    - Test without S3 features
#   with-s3  - Test with S3 features
#   all      - Test both scenarios (default)
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCENARIO="${1:-all}"
REGISTRY="ghcr.io"
LOCAL_REGISTRY="localhost:5001"
RUN_ID="${GITHUB_RUN_NUMBER:-local-$(date +%s)}"
SHORT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo 'local')"

# Functions
log_info() {
    echo -e "${BLUE}ℹ ${1}${NC}"
}

log_success() {
    echo -e "${GREEN}✓ ${1}${NC}"
}

log_error() {
    echo -e "${RED}✗ ${1}${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠ ${1}${NC}"
}

log_checkpoint() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║ $1${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

check_dependencies() {
    log_checkpoint "Checking dependencies..."
    
    local missing=()
    
    for cmd in docker kind kubectl helm kustomize flux cargo; do
        if ! command -v $cmd &> /dev/null; then
            missing+=($cmd)
        else
            log_success "$cmd found: $(command -v $cmd)"
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required dependencies: ${missing[*]}"
        echo ""
        echo "Install missing dependencies:"
        echo "  • Docker:     https://docs.docker.com/get-docker/"
        echo "  • kind:       brew install kind (or: go install sigs.k8s.io/kind@latest)"
        echo "  • kubectl:    brew install kubectl"
        echo "  • helm:       brew install helm"
        echo "  • kustomize:  brew install kustomize"
        echo "  • flux:       brew install fluxcd/tap/flux"
        echo "  • cargo:      https://rustup.rs/"
        exit 1
    fi
    
    # Check if Docker daemon is running
    if ! docker info > /dev/null 2>&1; then
        log_error "Docker daemon is not running"
        echo ""
        echo "Please start Docker Desktop and try again:"
        echo "  • macOS: Open Docker Desktop from Applications"
        echo "  • Linux: sudo systemctl start docker"
        echo ""
        echo "After Docker is running, re-run this script."
        exit 1
    fi
    
    log_success "All dependencies installed and Docker daemon is running"
}

run_scenario() {
    local scenario=$1
    local include_s3=$2
    
    log_checkpoint "Starting E2E test: ${scenario}"
    
    local cluster_name="e2e-${scenario}"
    local kubeconfig="/tmp/kind-kubeconfig-${scenario}"
    local image_tag="local-${RUN_ID}-${SHORT_SHA}"
    local app_image="${LOCAL_REGISTRY}/test-app-${scenario}:${image_tag}"
    local manifest_image="${LOCAL_REGISTRY}/manifests-${scenario}:${image_tag}"
    # Registry URL accessible from inside the cluster
    local cluster_registry="kind-registry-e2e:5000"
    local cluster_manifest_image="${cluster_registry}/manifests-${scenario}:${image_tag}"
    local generated_dir="./generated/test-app-${scenario}"
    
    export KUBECONFIG="${kubeconfig}"
    
    # Step 1: Setup Kind cluster
    log_checkpoint "Step 1/9: Setting up Kind cluster"
    
    kind delete cluster --name "${cluster_name}" 2>/dev/null || true
    
    # Create kind cluster with local registry (for caching)
    # Use Kubernetes v1.32.0 (required for Knative v1.20, stable on macOS)
    cat <<EOF | kind create cluster --name "${cluster_name}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."${LOCAL_REGISTRY}"]
    endpoint = ["http://kind-registry-e2e:5001"]
nodes:
- role: control-plane
  image: kindest/node:v1.32.0@sha256:c48c62eac5da28cdadcf560d1d8616cfa6783b58f0d94cf63ad1bf49600cb027
  extraPortMappings:
  - containerPort: 30080
    hostPort: 30080
EOF
    
    if [ $? -ne 0 ]; then
        log_error "Failed to create Kind cluster"
        echo ""
        echo "Troubleshooting tips:"
        echo "  1. Check Docker Desktop is running and healthy"
        echo "  2. Try: docker system prune -f"
        echo "  3. Try: kind delete cluster --name ${cluster_name}"
        echo "  4. See docs/E2E_TROUBLESHOOTING.md for more help"
        exit 1
    fi
    
    # Connect local registry to kind network if not already connected
    if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' kind-registry-e2e 2>/dev/null)" = 'null' ]; then
        docker network connect kind kind-registry-e2e || true
    fi
    
    kind get kubeconfig --name "${cluster_name}" > "${kubeconfig}"
    log_success "Kind cluster created: ${cluster_name} (Kubernetes v1.32.0)"
    
    # Step 2: Generate project from template
    log_checkpoint "Step 2/9: Generating project from template"
    
    cat > template-values-${scenario}.toml <<EOF
[values]
project_name = "test-app"
project_author = "E2E Bot <e2e@local.dev>"
features = $(if [[ "${include_s3}" == "true" ]]; then echo '["s3"]'; else echo '[]'; fi)
event_sources = []
enable_image_updates = false
target_namespace = "default"
github_org = "test-org"
github_repo = "test-repo"
default_branch = "main"
image_registry = "${LOCAL_REGISTRY}"
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
EOF
    
    # Check if cargo-generate is installed
    if ! command -v cargo-generate &> /dev/null; then
        log_info "Installing cargo-generate (cached after first run)..."
        cargo install cargo-generate --locked
    fi
    
    cargo generate --path . \
        --name "test-app-${scenario}" \
        --template-values-file "template-values-${scenario}.toml" \
        --allow-commands
    
    mkdir -p ./generated
    mv "test-app-${scenario}" ./generated/ 2>/dev/null || true
    
    log_success "Project generated: ${generated_dir}"
    
    # Step 3: Validate generated structure
    log_checkpoint "Step 3/9: Validating generated structure"
    
    required_files=(
        "${generated_dir}/Cargo.toml"
        "${generated_dir}/src/main.rs"
        "${generated_dir}/Dockerfile"
        "${generated_dir}/deploy/base/knative-service.yaml"
        "${generated_dir}/deploy/base/kustomization.yaml"
    )
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            log_error "Missing required file: $file"
            exit 1
        fi
        log_success "Found: $file"
    done
    
    log_success "Structure validation passed"
    
    # Step 4: Build application image
    log_checkpoint "Step 4/9: Building application image"
    
    # Build for linux/amd64 (x86_64) to match target in Dockerfile
    docker build --platform linux/amd64 -t "${app_image}" "${generated_dir}"
    docker push "${app_image}"
    
    # Load into kind cluster
    kind load docker-image "${app_image}" --name "${cluster_name}"
    
    log_success "Application image built and loaded: ${app_image}"
    
    # Step 5: Prepare and push manifests as OCI artifact
    log_checkpoint "Step 5/9: Preparing manifests"
    
    cd "${generated_dir}/deploy/base"
    
    cat > kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - knative-service.yaml

images:
  - name: ghcr.io/test-org/test-app
    newName: ${LOCAL_REGISTRY}/test-app-${scenario}
    newTag: ${image_tag}

namespace: default
EOF
    
    mkdir -p ../../manifests-built
    kustomize build . --load-restrictor LoadRestrictionsNone > ../../manifests-built/all.yaml
    
    cd - > /dev/null
    
    log_info "Pushing manifests as OCI artifact..."
    flux push artifact \
        "oci://${manifest_image}" \
        --path "${generated_dir}/manifests-built" \
        --source="file://$(pwd)" \
        --revision="${SHORT_SHA}"
    
    log_success "Manifests prepared and pushed"
    
    # Step 6: Install Flux controllers
    log_checkpoint "Step 6/9: Installing Flux"
    
    flux install
    
    kubectl wait --for=condition=available \
        --timeout=180s \
        -n flux-system \
        deployment/source-controller \
        deployment/kustomize-controller
    
    log_success "Flux installed"
    
    # Step 7: Install Knative Serving
    log_checkpoint "Step 7/9: Installing Knative Serving"
    
    # Knative v1.20.0 requires Kubernetes v1.32+ (we use v1.32.0)
    KNATIVE_VERSION="knative-v1.20.0"
    
    kubectl apply -f "https://github.com/knative/serving/releases/download/${KNATIVE_VERSION}/serving-crds.yaml"
    kubectl apply -f "https://github.com/knative/serving/releases/download/${KNATIVE_VERSION}/serving-core.yaml"
    kubectl apply -f "https://github.com/knative/net-kourier/releases/download/${KNATIVE_VERSION}/kourier.yaml"
    
    kubectl patch configmap/config-network \
        --namespace knative-serving \
        --type merge \
        --patch '{"data":{"ingress-class":"kourier.ingress.networking.knative.dev"}}'
    
    kubectl wait --for=condition=available \
        --timeout=300s \
        -n knative-serving \
        deployment/activator \
        deployment/autoscaler \
        deployment/controller \
        deployment/webhook
    
    log_success "Knative Serving installed"
    
    # Step 8: Install infrastructure services
    log_checkpoint "Step 8/9: Installing infrastructure (Redis, MinIO)"
    
    # Redis
    helm repo add bitnami https://charts.bitnami.com/bitnami > /dev/null 2>&1 || true
    helm repo update > /dev/null 2>&1
    
    helm install redis bitnami/redis \
        --set auth.enabled=false \
        --set architecture=standalone \
        --wait \
        --timeout 120s
    
    log_success "Redis installed"
    
    # MinIO (if needed)
    if [[ "${include_s3}" == "true" ]]; then
        helm repo add minio https://charts.min.io/ > /dev/null 2>&1 || true
        helm repo update > /dev/null 2>&1
        
        helm install minio minio/minio \
            --set replicas=1 \
            --set mode=standalone \
            --set resources.requests.memory=256Mi \
            --set rootUser=minioadmin \
            --set rootPassword=minioadmin \
            --wait \
            --timeout 180s
        
        log_success "MinIO installed"
    fi
    
    # Create application secrets
    if [[ "${include_s3}" == "true" ]]; then
        kubectl create secret generic rust-service-secrets \
            --from-literal=redis-url=redis://redis-master:6379 \
            --from-literal=aws-access-key-id=minioadmin \
            --from-literal=aws-secret-access-key=minioadmin \
            --dry-run=client -o yaml | kubectl apply -f -
    else
        kubectl create secret generic rust-service-secrets \
            --from-literal=redis-url=redis://redis-master:6379 \
            --dry-run=client -o yaml | kubectl apply -f -
    fi
    
    log_success "Infrastructure installed"
    
    # Step 9: Deploy application via Flux
    log_checkpoint "Step 9/9: Deploying application via Flux"
    
    cat <<EOF | kubectl apply -f -
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: test-app-${scenario}
  namespace: flux-system
spec:
  interval: 1m
  url: oci://${cluster_manifest_image%:*}
  ref:
    tag: "${image_tag}"
  insecure: true
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: test-app-${scenario}
  namespace: flux-system
spec:
  interval: 1m
  sourceRef:
    kind: OCIRepository
    name: test-app-${scenario}
  path: ./
  prune: true
  targetNamespace: default
  wait: true
  timeout: 5m
EOF
    
    # Wait for Flux reconciliation
    log_info "Waiting for Flux reconciliation..."
    
    kubectl wait --for=condition=ready \
        --timeout=180s \
        -n flux-system \
        "ocirepository/test-app-${scenario}" || {
            log_error "OCIRepository failed to become ready"
            kubectl describe "ocirepository/test-app-${scenario}" -n flux-system
            exit 1
        }
    
    kubectl wait --for=condition=ready \
        --timeout=300s \
        -n flux-system \
        "kustomization/test-app-${scenario}" || {
            log_error "Kustomization failed to become ready"
            kubectl describe "kustomization/test-app-${scenario}" -n flux-system
            exit 1
        }
    
    # Wait for Knative Service
    log_info "Waiting for Knative Service to be ready..."
    
    kubectl wait --for=condition=ready \
        --timeout=300s \
        ksvc/rust-service || {
            log_error "Knative Service not ready"
            kubectl describe ksvc/rust-service
            kubectl logs -l serving.knative.dev/service=rust-service --tail=100 || true
            exit 1
        }
    
    log_success "Application deployed"
    
    # Run E2E tests
    log_checkpoint "Running E2E tests"
    
    SERVICE_URL=$(kubectl get ksvc rust-service -o jsonpath='{.status.url}')
    log_info "Service URL: ${SERVICE_URL}"
    
    # Helper function to run curl inside the cluster
    kubectl_curl() {
        kubectl run "curl-test-$RANDOM" --image=curlimages/curl:latest --rm -i --restart=Never -- "$@" 2>&1 | grep -v "pod.*deleted"
    }
    
    FAILED=0
    
    echo ""
    log_info "Test: Liveness probe..."
    if kubectl_curl -f -s "${SERVICE_URL}/health/live" > /dev/null 2>&1; then
        log_success "Liveness probe PASSED"
    else
        log_error "Liveness probe FAILED"
        ((FAILED++))
    fi
    
    echo ""
    log_info "Test: Readiness probe..."
    if kubectl_curl -f -s "${SERVICE_URL}/health/ready" > /dev/null 2>&1; then
        log_success "Readiness probe PASSED"
    else
        log_error "Readiness probe FAILED"
        ((FAILED++))
    fi
    
    echo ""
    log_info "Test: Prometheus metrics..."
    METRICS_OUTPUT=$(kubectl_curl -f -s "${SERVICE_URL}/metrics")
    if echo "$METRICS_OUTPUT" | grep -q '# HELP' && echo "$METRICS_OUTPUT" | grep -q '# TYPE'; then
        log_success "Metrics endpoint PASSED"
    else
        log_error "Metrics endpoint FAILED"
        ((FAILED++))
    fi
    
    echo ""
    log_info "Test: Hello API..."
    RESPONSE=$(kubectl_curl -f -s "${SERVICE_URL}/api/v1/hello")
    if echo "$RESPONSE" | grep -q '"message"'; then
        log_success "Hello API PASSED"
    else
        log_error "Hello API FAILED"
        ((FAILED++))
    fi
    
    if [[ "${include_s3}" == "true" ]]; then
        echo ""
        log_info "Test: S3 storage example..."
        RESPONSE=$(kubectl_curl -f -s -X POST "${SERVICE_URL}/api/v1/storage/example")
        
        if echo "$RESPONSE" | grep -q '"success":true' && \
           echo "$RESPONSE" | grep -q '"read_verified":true'; then
            log_success "S3 storage PASSED"
        else
            log_error "S3 storage FAILED"
            echo "Response: $RESPONSE"
            ((FAILED++))
        fi
    fi
    
    echo ""
    log_checkpoint "Test Summary: ${scenario}"
    
    if [ $FAILED -eq 0 ]; then
        log_success "All tests PASSED for scenario: ${scenario}"
        echo ""
        echo "Cluster still running for debugging:"
        echo "  export KUBECONFIG=${kubeconfig}"
        echo "  kubectl get pods -A"
        echo "  kubectl logs -l serving.knative.dev/service=rust-service -f"
        echo ""
        echo "To clean up:"
        echo "  kind delete cluster --name ${cluster_name}"
        return 0
    else
        log_error "${FAILED} test(s) FAILED for scenario: ${scenario}"
        echo ""
        echo "Debug information:"
        echo "  export KUBECONFIG=${kubeconfig}"
        echo "  kubectl get pods -A"
        echo "  kubectl logs -l serving.knative.dev/service=rust-service --tail=100"
        echo "  kubectl describe ksvc/rust-service"
        return 1
    fi
}

cleanup_on_exit() {
    if [[ "${KEEP_CLUSTER:-false}" != "true" ]]; then
        log_info "Cleaning up (set KEEP_CLUSTER=true to preserve clusters)..."
        kind delete cluster --name "e2e-no-s3" 2>/dev/null || true
        kind delete cluster --name "e2e-with-s3" 2>/dev/null || true
    fi
}

# Main execution
main() {
    log_checkpoint "Template E2E Test - Local Runner"
    
    check_dependencies
    
    # Setup local registry for caching
    log_info "Setting up local registry for caching..."
    
    if ! docker ps | grep -q kind-registry-e2e; then
        docker run -d \
            --name kind-registry-e2e \
            --restart always \
            -p 5001:5000 \
            registry:2 2>/dev/null || true
    fi
    
    log_success "Local registry ready at ${LOCAL_REGISTRY}"
    
    # Trap cleanup
    trap cleanup_on_exit EXIT
    
    # Run scenarios
    case "${SCENARIO}" in
        no-s3)
            run_scenario "no-s3" "false"
            ;;
        with-s3)
            run_scenario "with-s3" "true"
            ;;
        all)
            run_scenario "no-s3" "false"
            echo ""
            run_scenario "with-s3" "true"
            ;;
        *)
            log_error "Unknown scenario: ${SCENARIO}"
            echo "Valid scenarios: no-s3, with-s3, all"
            exit 1
            ;;
    esac
    
    log_checkpoint "E2E Test Complete!"
}

main "$@"
