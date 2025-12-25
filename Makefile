.DEFAULT_GOAL := help

# Configuration
CLUSTER_NAME := dev
KUBECONFIG_PATH := .kubeconfig-dev
REGISTRY_PORT := 5001
PROJECT_NAME := $(shell grep '^name' Cargo.toml | head -1 | sed 's/name = "\(.*\)"/\1/')

# Colored output
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[0;33m
BLUE := \033[0;34m
NC := \033[0m # No Color

.PHONY: help
help: ## Show this help message
	@echo 'Rust Knative Flux Template - Development Commands'
	@echo ''
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  ${GREEN}%-25s${NC} %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ============================================================================
# Primary Developer Commands
# ============================================================================

.PHONY: dev-up
dev-up: ## Start full development environment (cluster + all services)
	@echo "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
	@echo "${BLUE}║      Starting Development Environment (Kind)           ║${NC}"
	@echo "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
	@echo ""
	@echo "${YELLOW}[1/6]${NC} Creating Kind cluster and registry..."
	@./scripts/dev/setup-kind.sh || { echo "${RED}✗ Failed to setup cluster${NC}"; exit 1; }
	@echo ""
	@echo "${YELLOW}[2/6]${NC} Installing Knative Serving v1.20.0..."
	@./scripts/dev/install-knative.sh || { echo "${RED}✗ Failed to install Knative${NC}"; exit 1; }
	@echo ""
	@echo "${YELLOW}[3/6]${NC} Deploying infrastructure services..."
	@./scripts/dev/deploy-infrastructure.sh || { echo "${RED}✗ Failed to deploy infrastructure${NC}"; exit 1; }
	@echo ""
	@echo "${YELLOW}[4/6]${NC} Deploying observability stack (required)..."
	@./scripts/dev/deploy-observability.sh || { echo "${RED}✗ Failed to deploy observability${NC}"; exit 1; }
	@echo ""
	@echo "${YELLOW}[5/6]${NC} Building and deploying application..."
	@./scripts/dev/build-and-deploy.sh || { echo "${RED}✗ Failed to deploy application${NC}"; exit 1; }
	@echo ""
	@echo "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
	@echo "${BLUE}║         ✓ Development Environment Ready!               ║${NC}"
	@echo "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
	@echo ""
	@echo "${YELLOW}Next steps:${NC}"
	@echo ""
	@echo "  1. Start port forwarding (in another terminal):"
	@echo "     ${GREEN}make dev-forward${NC}"
	@echo ""
	@echo "  2. Access your services:"
	@echo "     • Application:   ${GREEN}http://localhost:8080${NC}"
	@echo "     • Jaeger UI:     ${GREEN}http://localhost:16686${NC}"
	@echo "     • Prometheus:    ${GREEN}http://localhost:9090${NC}"
	@echo "     • Redis:         ${GREEN}localhost:6379${NC}"
	@echo "     • MinIO Console: ${GREEN}http://localhost:9001${NC} (admin/minioadmin)"
	@echo "     • MinIO API:     ${GREEN}http://localhost:9000${NC}"
	@echo ""
	@echo "  3. View application logs:"
	@echo "     ${GREEN}make dev-logs${NC}"
	@echo ""
	@echo "  4. Rebuild after code changes:"
	@echo "     ${GREEN}make dev-restart${NC}"
	@echo ""
	@echo "  5. Tear down when done:"
	@echo "     ${GREEN}make dev-down${NC}"

.PHONY: dev-down
dev-down: ## Stop and delete development environment
	@echo "${YELLOW}Stopping development environment...${NC}"
	@kind delete cluster --name $(CLUSTER_NAME) 2>/dev/null || true
	@docker stop kind-registry-dev 2>/dev/null || true
	@docker rm kind-registry-dev 2>/dev/null || true
	@pkill -f "kubectl.*port-forward" 2>/dev/null || true
	@rm -f $(KUBECONFIG_PATH)
	@echo "${GREEN}✓ Dev environment cleaned up${NC}"

.PHONY: dev-restart
dev-restart: ## Rebuild and redeploy application (with docker image rebuild)
	@echo "${YELLOW}Rebuilding and redeploying application...${NC}"
	@./scripts/dev/build-and-deploy.sh || { echo "${RED}✗ Failed to redeploy${NC}"; exit 1; }
	@echo "${GREEN}✓ Application redeployed${NC}"

.PHONY: dev-logs
dev-logs: ## Stream application logs
	@export KUBECONFIG=$(KUBECONFIG_PATH) && \
		kubectl logs -f -l serving.knative.dev/service='$(PROJECT_NAME)' -c user-container --all-containers=false 2>/dev/null || \
		echo "${RED}No logs available. Is the application deployed?${NC}"

.PHONY: dev-status
dev-status: ## Show status of all services
	@export KUBECONFIG=$(KUBECONFIG_PATH) && \
		echo "${GREEN}=== Kubernetes Cluster ===${NC}" && \
		kubectl cluster-info && \
		echo "" && \
		echo "${GREEN}=== Infrastructure Services (namespace: services) ===${NC}" && \
		kubectl get pods -n services 2>/dev/null || echo "No services namespace" && \
		echo "" && \
		echo "${GREEN}=== Observability Stack (namespace: observability) ===${NC}" && \
		kubectl get pods -n observability 2>/dev/null || echo "No observability namespace" && \
		echo "" && \
		echo "${GREEN}=== Application (namespace: default) ===${NC}" && \
		kubectl get ksvc,pods -n default 2>/dev/null || echo "No services deployed"

.PHONY: dev-shell
dev-shell: ## Open shell in application pod
	@export KUBECONFIG=$(KUBECONFIG_PATH) && \
		POD=$$(kubectl get pod -l serving.knative.dev/service='$(PROJECT_NAME)' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) && \
		if [ -z "$$POD" ]; then \
			echo "${RED}No running pod found. Is the application deployed?${NC}"; \
			exit 1; \
		fi && \
		kubectl exec -it $$POD -c user-container -- /bin/sh || \
		echo "${RED}Failed to open shell${NC}"

.PHONY: dev-forward
dev-forward: ## Start port forwarding for all services (run in separate terminal)
	@./scripts/dev/port-forward.sh

.PHONY: dev-test-health
dev-test-health: ## Quick health check of application
	@echo "${YELLOW}Testing application health...${NC}"
	@curl -sf http://localhost:8080/health/live >/dev/null 2>&1 && echo "${GREEN}✓ Liveness check passed${NC}" || echo "${RED}✗ Liveness check failed${NC}"
	@curl -sf http://localhost:8080/health/ready >/dev/null 2>&1 && echo "${GREEN}✓ Readiness check passed${NC}" || echo "${RED}✗ Readiness check failed${NC}"

.PHONY: dev-send-event
dev-send-event: ## Send a test CloudEvent to the service
	@./scripts/dev/send-test-event.sh localhost:8080 com.example.ping "Test event from make target"

# ============================================================================
# Component-Specific Commands
# ============================================================================

.PHONY: dev-cluster
dev-cluster: ## Create Kind cluster and registry only
	@./scripts/dev/setup-kind.sh

.PHONY: dev-infra
dev-infra: ## Deploy infrastructure services (Redis, MinIO) only
	@./scripts/dev/deploy-infrastructure.sh

.PHONY: dev-observability
dev-observability: ## Deploy observability stack (Jaeger, Prometheus, OTel) only
	@./scripts/dev/deploy-observability.sh

.PHONY: dev-deploy
dev-deploy: ## Deploy application only (assumes image exists in registry)
	@export KUBECONFIG=$(KUBECONFIG_PATH) && \
		kubectl apply -k deploy/overlays/dev

# ============================================================================
# Testing Commands
# ============================================================================

.PHONY: dev-test
dev-test: ## Run integration tests against Kind cluster
	@export KUBECONFIG=$(KUBECONFIG_PATH) && \
		cargo test -- --ignored --nocapture

# ============================================================================
# Utility Commands
# ============================================================================

.PHONY: dev-clean
dev-clean: dev-down ## Clean everything (alias for dev-down)

.PHONY: dev-reset
dev-reset: dev-down dev-up ## Nuclear option - delete and recreate everything

.PHONY: dev-kubeconfig
dev-kubeconfig: ## Show kubeconfig export command
	@echo "export KUBECONFIG=$(PWD)/$(KUBECONFIG_PATH)"

.PHONY: dev-get-url
dev-get-url: ## Get the application URL
	@export KUBECONFIG=$(KUBECONFIG_PATH) && \
		kubectl get ksvc '$(PROJECT_NAME)' -n default -o jsonpath='{.status.url}' 2>/dev/null || \
		echo "${RED}Application not found${NC}"
