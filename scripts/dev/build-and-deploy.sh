#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
KUBECONFIG_PATH="${PROJECT_ROOT}/.kubeconfig-dev"
REGISTRY_PORT="5001"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

if [[ ! -f "$KUBECONFIG_PATH" ]]; then
	echo -e "${RED}✗ Error: Kubeconfig not found at ${KUBECONFIG_PATH}${NC}"
	echo "Run 'make dev-cluster' first"
	exit 1
fi

export KUBECONFIG="$KUBECONFIG_PATH"

echo "Building and deploying application..."
echo ""

# Check if this is a template project (Cargo.toml.liquid with template variables)
if [[ -f "${PROJECT_ROOT}/Cargo.toml.liquid" ]] && grep -q {% raw %} "{{ crate_name }}" {% endraw %} "${PROJECT_ROOT}/Cargo.toml.liquid"; then
	echo -e "${YELLOW}⚠ Template Project Detected${NC}"
	echo "This is a cargo-generate template repository."
	echo ""
	echo "To use this template:"
	echo "  1. Create a new project: cargo generate --path <path-to-this-template>"
	echo "  2. Or use it directly by rendering templates first"
	echo ""
	echo -e "${YELLOW}→${NC} Skipping application deployment (no concrete project to build)"
	echo ""
	echo -e "${GREEN}✓ Infrastructure is ready for a generated project${NC}"
	echo ""
	exit 0
fi

# Extract project name from Cargo.toml
if [[ ! -f "${PROJECT_ROOT}/Cargo.toml" ]]; then
	echo -e "${RED}✗ Error: Cargo.toml not found${NC}"
	echo "This is a template project. Please generate a project using cargo-generate first."
	exit 1
fi

PROJECT_NAME=$(grep '^name = ' "${PROJECT_ROOT}/Cargo.toml" | head -1 | sed 's/name = "\(.*\)"/\1/')

if [[ -z "$PROJECT_NAME" ]]; then
	echo -e "${RED}✗ Error: Could not determine project name${NC}"
	exit 1
fi

IMAGE="localhost:${REGISTRY_PORT}/${PROJECT_NAME}:latest"

# Build Docker image
echo -e "${YELLOW}→${NC} Building Docker image: ${IMAGE}"
if ! docker build -t "${IMAGE}" "${PROJECT_ROOT}"; then
	echo -e "${RED}✗ Error: Docker build failed${NC}"
	exit 1
fi

# Push to local registry
echo -e "${YELLOW}→${NC} Pushing image to local registry..."
if ! docker push "${IMAGE}"; then
	echo -e "${RED}✗ Error: Failed to push image to registry${NC}"
	exit 1
fi

# Apply Knative service
echo -e "${YELLOW}→${NC} Deploying to Knative..."
if ! kubectl apply -k "${PROJECT_ROOT}/deploy/overlays/dev"; then
	echo -e "${RED}✗ Error: Failed to apply Knative manifests${NC}"
	exit 1
fi

# Wait for service to be ready
echo -e "${YELLOW}→${NC} Waiting for Knative service to be ready..."
if ! kubectl wait --for=condition=Ready ksvc/"${PROJECT_NAME}" -n default --timeout=5m; then
	echo -e "${RED}✗ Error: Knative service failed to become ready${NC}"
	echo ""
	echo "Service status:"
	kubectl get ksvc "${PROJECT_NAME}" -n default -o yaml
	echo ""
	echo "Pod status:"
	kubectl get pods -n default
	echo ""
	echo "Recent logs:"
	kubectl logs -l serving.knative.dev/service="${PROJECT_NAME}" -c user-container -n default --tail=50 2>/dev/null || echo "No logs available"
	exit 1
fi

echo ""
echo -e "${GREEN}✓ Application deployed successfully${NC}"
echo ""

# Get service URL
SERVICE_URL=$(kubectl get ksvc "${PROJECT_NAME}" -n default -o jsonpath='{.status.url}' 2>/dev/null || echo "")
if [[ -n "$SERVICE_URL" ]]; then
	echo -e "Service URL: ${GREEN}${SERVICE_URL}${NC}"
else
	echo "Service URL: (pending)"
fi

kubectl get ksvc "${PROJECT_NAME}" -n default
echo ""
