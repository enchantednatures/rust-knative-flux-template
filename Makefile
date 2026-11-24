.DEFAULT_GOAL := help

# Configuration
CLUSTER_NAME := dev
# Kubeconfig for the local Kind cluster created by `make local-up`.
KUBECONFIG_PATH := .kubeconfig-dev
# Kubeconfig for the Flux bootstrap/deploy targets (a real cluster).
# Override per invocation: make deploy dev KUBECONFIG=... (or CLUSTER_KUBECONFIG=...)
CLUSTER_KUBECONFIG ?= $(HOME)/.kube/config
REGISTRY_PORT := 5001
# Service name (normalized with hyphens for Kubernetes)
PROJECT_NAME := {{ project_name | replace: "_", "-" }}
# Binary name (with underscores as per Rust convention)
CRATE_NAME := {{ crate_name }}

# Canonical service slug (kebab-case) for the per-service dev tooling. The first
# service is the project itself; added services live in services/<SERVICE>.
# Underscores are normalized so `SERVICE=orders_api` still selects `orders-api`.
SERVICE ?= $(PROJECT_NAME)
# `override` is required: command-line variables otherwise win over this
# normalization, leaving SERVICE=orders_api un-canonicalized for every target.
override SERVICE := $(subst _,-,$(SERVICE))
# Directory holding the selected service's source/config (`.` = first service).
SERVICE_DIR := $(if $(wildcard services/$(SERVICE)),services/$(SERVICE),.)
# Production image base. Added services append `-<SERVICE>`; the first service
# keeps the project image unchanged.
IMAGE ?= {{ image_registry }}/{{ github_org }}/$(PROJECT_NAME)
SERVICE_IMAGE := $(if $(filter $(PROJECT_NAME),$(SERVICE)),$(IMAGE),$(IMAGE)-$(SERVICE))

# Kafka resources are per service; the broker itself stays shared.
KAFKA_CONSUMER_GROUP ?= $(if $(filter $(PROJECT_NAME),$(SERVICE)),$(CRATE_NAME)-consumers,$(SERVICE)-consumers)
KAFKA_SOURCE_NAME ?= $(if $(filter $(PROJECT_NAME),$(SERVICE)),$(PROJECT_NAME)-kafka-source,$(SERVICE)-kafka-source)
DLQ_SERVICE_NAME ?= $(if $(filter $(PROJECT_NAME),$(SERVICE)),$(PROJECT_NAME)-dlq,$(SERVICE)-dlq)
# PostgreSQL is shared; only the database used by the psql helper is per service.
POSTGRES_DB ?= $(if $(filter $(PROJECT_NAME),$(SERVICE)),app,$(subst -,_,$(SERVICE)))

# add-service 1/0 convenience switches (empty keeps the helper's defaults).
add_bool_flag = $(if $(filter 1 true yes,$(strip $(1))),$(2),$(if $(filter 0 false no,$(strip $(1))),$(3)))
ADD_SERVICE_SLUG := $(subst _,-,$(NAME))
ADD_SERVICE_ARGS :=
ifneq ($(strip $(WORKLOAD)),)
ADD_SERVICE_ARGS += --workload $(strip $(WORKLOAD))
endif
ifneq ($(strip $(POSTGRES)),)
ADD_SERVICE_ARGS += $(call add_bool_flag,$(POSTGRES),--postgres,--no-postgres)
endif
ifneq ($(strip $(S3)),)
ADD_SERVICE_ARGS += $(call add_bool_flag,$(S3),--s3,--no-s3)
endif
ifneq ($(strip $(KAFKA_PUBLISH)),)
ADD_SERVICE_ARGS += $(call add_bool_flag,$(KAFKA_PUBLISH),--kafka-publish,--no-kafka-publish)
endif
ifneq ($(strip $(KAFKA_SOURCE)),)
ADD_SERVICE_ARGS += $(call add_bool_flag,$(KAFKA_SOURCE),--kafka-source,--no-kafka-source)
endif
ifneq ($(strip $(ENABLE_FLAGGER)),)
ADD_SERVICE_ARGS += $(call add_bool_flag,$(ENABLE_FLAGGER),--enable-flagger,--no-flagger)
endif
ifneq ($(strip $(KAFKA_BROKER_URL)),)
ADD_SERVICE_ARGS += --kafka-broker-url $(strip $(KAFKA_BROKER_URL))
endif
ifneq ($(strip $(DRY_RUN)),)
ADD_SERVICE_ARGS += $(call add_bool_flag,$(DRY_RUN),--dry-run,)
endif

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

.PHONY: local-up
local-up: ## Start full local development environment (Kind + all services)
	@echo "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
	@echo "${BLUE}║      Starting Development Environment (Kind)           ║${NC}"
	@echo "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
	@echo ""
	@echo "${YELLOW}[1/6]${NC} Creating Kind cluster and registry..."
	@./scripts/dev/setup-kind.sh || { echo "${RED}✗ Failed to setup cluster${NC}"; exit 1; }
	@echo ""
	{% if workload_type == "Knative" %}
	@echo "${YELLOW}[2/6]${NC} Installing Knative Serving v1.20.0..."
	@./scripts/dev/install-knative.sh || { echo "${RED}✗ Failed to install Knative${NC}"; exit 1; }
	@echo ""
	{% endif %}
	@echo "${YELLOW}[3/6]${NC} Deploying infrastructure services..."
	@./scripts/dev/deploy-infrastructure.sh || { echo "${RED}✗ Failed to deploy infrastructure${NC}"; exit 1; }
	@echo ""
	@echo "${YELLOW}[4/6]${NC} Deploying observability stack (required)..."
	@./scripts/dev/deploy-observability.sh || { echo "${RED}✗ Failed to deploy observability${NC}"; exit 1; }
	@echo ""
{%- if feature_postgres %}
	@echo "${YELLOW}[5/6]${NC} Waiting for CNPG operator and deploying PostgreSQL..."
	@./scripts/dev/deploy-postgres.sh dev --kustomize deploy/dev/app-overlay || { echo "${RED}✗ Failed to deploy PostgreSQL${NC}"; exit 1; }
	@echo ""
{%- endif %}
	@echo "${YELLOW}[6/6]${NC} Building and deploying application (service: $(SERVICE))..."
	@./scripts/dev/build-and-deploy.sh --service '$(SERVICE)' || { echo "${RED}✗ Failed to deploy application${NC}"; exit 1; }
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
	@echo "     • RustFS Console: ${GREEN}http://localhost:9001${NC} (rustfsadmin/rustfsadmin)"
	@echo "     • RustFS API:     ${GREEN}http://localhost:9000${NC}"
	@echo "     • Kafka:         ${GREEN}kafka.kafka.svc.cluster.local:9092${NC} (if Kafka enabled)"
	@echo ""
	@echo "  3. Send test Kafka event (if Kafka enabled):"
	@echo "     ${GREEN}make kafka-send-event${NC}"
	@echo ""
	@echo "  4. View application logs:"
	@echo "     ${GREEN}make dev-logs${NC}"
	@echo ""
	@echo "  4. Rebuild after code changes:"
	@echo "     ${GREEN}make dev-restart${NC}"
	@echo ""
	@echo "  5. Tear down when done:"
	@echo "     ${GREEN}make local-down${NC}"

.PHONY: dev-up
dev-up: local-up ## [deprecated] Alias for local-up

.PHONY: local-down
local-down: ## Stop and delete the local development environment
	@echo "${YELLOW}Stopping development environment...${NC}"
	@kind delete cluster --name $(CLUSTER_NAME) 2>/dev/null || true
	@docker stop kind-registry-dev 2>/dev/null || true
	@docker rm kind-registry-dev 2>/dev/null || true
	@pkill -f "kubectl.*port-forward" 2>/dev/null || true
	@rm -f $(KUBECONFIG_PATH)
	@echo "${GREEN}✓ Dev environment cleaned up${NC}"

.PHONY: dev-down
dev-down: local-down ## [deprecated] Alias for local-down

.PHONY: dev-restart
dev-restart: ## Rebuild and redeploy application (with docker image rebuild)
	@echo "${YELLOW}Rebuilding and redeploying application (service: $(SERVICE))...${NC}"
	@./scripts/dev/build-and-deploy.sh --service '$(SERVICE)' || { echo "${RED}✗ Failed to redeploy${NC}"; exit 1; }
	@echo "${GREEN}✓ Application redeployed${NC}"

.PHONY: dev-logs
dev-logs: ## Stream application logs (SERVICE=<slug>)
	@export KUBECONFIG=$(KUBECONFIG_PATH) && \
		if kubectl get ksvc '$(SERVICE)' -n default >/dev/null 2>&1; then \
			kubectl logs -f -l serving.knative.dev/service='$(SERVICE)' -c user-container --all-containers=false 2>/dev/null || \
				echo "${RED}No logs available. Is '$(SERVICE)' deployed?${NC}"; \
		elif kubectl get deployment '$(SERVICE)' -n default >/dev/null 2>&1; then \
			kubectl logs -f -l app.kubernetes.io/instance='$(SERVICE)' --all-containers=true 2>/dev/null || \
				echo "${RED}No logs available. Is '$(SERVICE)' deployed?${NC}"; \
		else \
			echo "${RED}No Knative Service or Deployment named '$(SERVICE)' found.${NC}"; \
		fi

.PHONY: dev-status
dev-status: ## Show status of all services (SERVICE=<slug>)
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
		echo "${GREEN}=== Service: $(SERVICE) (namespace: default) ===${NC}" && \
		if [ '$(SERVICE)' = '$(PROJECT_NAME)' ]; then \
			kubectl get ksvc,pods -n default 2>/dev/null || echo "No services deployed"; \
		else \
			kubectl get ksvc,deployment,pods -n default -l app.kubernetes.io/instance='$(SERVICE)' 2>/dev/null || \
				kubectl get pods -n default -l app.kubernetes.io/instance='$(SERVICE)' 2>/dev/null || \
				echo "No resources found for '$(SERVICE)'"; \
		fi

.PHONY: dev-shell
dev-shell: ## Open shell in application pod (SERVICE=<slug>)
	@export KUBECONFIG=$(KUBECONFIG_PATH) && \
		if kubectl get ksvc '$(SERVICE)' -n default >/dev/null 2>&1; then \
			POD=$$(kubectl get pod -l serving.knative.dev/service='$(SERVICE)' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
			CONTAINER=user-container; \
		else \
			POD=$$(kubectl get pod -l app.kubernetes.io/instance='$(SERVICE)' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
			CONTAINER=$$(kubectl get pod "$$POD" -o jsonpath='{.spec.containers[0].name}' 2>/dev/null); \
		fi && \
		if [ -z "$$POD" ]; then \
			echo "${RED}No running pod found for '$(SERVICE)'. Is it deployed?${NC}"; \
			exit 1; \
		fi && \
		kubectl exec -it $$POD -c "$${CONTAINER:-user-container}" -- /bin/sh || \
		echo "${RED}Failed to open shell${NC}"

.PHONY: dev-forward
dev-forward: ## Start port forwarding (SERVICE=<slug> forwards that workload too)
	@if [ '$(SERVICE)' = '$(PROJECT_NAME)' ]; then \
		./scripts/dev/port-forward.sh; \
	else \
		./scripts/dev/port-forward.sh --service '$(SERVICE)'; \
	fi

.PHONY: dev-test-health
dev-test-health: ## Quick health check of application
	@echo "${YELLOW}Testing application health...${NC}"
	@curl -sf http://localhost:8080/health/live >/dev/null 2>&1 && echo "${GREEN}✓ Liveness check passed${NC}" || echo "${RED}✗ Liveness check failed${NC}"
	@curl -sf http://localhost:8080/health/ready >/dev/null 2>&1 && echo "${GREEN}✓ Readiness check passed${NC}" || echo "${RED}✗ Readiness check failed${NC}"

.PHONY: dev-send-event
dev-send-event: ## Send a test CloudEvent to the service
	@./scripts/dev/send-test-event.sh localhost:8080 com.example.ping "Test event from make target"

# Adds services/<slug> via scripts/add-service.sh. Boolean switches accept 1/0;
# leave them unset to use the helper's detected defaults. Extra flags can be
# passed through with ARGS='--flag ...'.
.PHONY: add-service
add-service: ## Add a service (usage: make add-service NAME=<slug> [WORKLOAD=knative|deployment] ...)
	@if [ -z '$(NAME)' ]; then \
		echo "${RED}Error: NAME is required${NC}"; \
		echo "Usage: make add-service NAME=<slug> [WORKLOAD=knative|deployment] [POSTGRES=1|0] [S3=1|0] [KAFKA_PUBLISH=1|0] [KAFKA_SOURCE=1|0] [ENABLE_FLAGGER=1|0] [KAFKA_BROKER_URL=host:port] [DRY_RUN=1] [ARGS='...']"; \
		exit 2; \
	fi
	@if [ ! -f scripts/add-service.sh ]; then \
		echo "${RED}✗ scripts/add-service.sh not found${NC}"; \
		echo "This target is installed by the service-template feature."; \
		exit 1; \
	fi
	./scripts/add-service.sh --name '$(ADD_SERVICE_SLUG)' $(ADD_SERVICE_ARGS) $(ARGS)

# ============================================================================
# Component-Specific Commands
# ============================================================================

.PHONY: dev-cluster
dev-cluster: ## Create Kind cluster and registry only
	@./scripts/dev/setup-kind.sh

.PHONY: dev-infra
dev-infra: ## Deploy infrastructure services (Redis, RustFS) only
	@./scripts/dev/deploy-infrastructure.sh

.PHONY: dev-observability
dev-observability: ## Deploy observability stack (Jaeger, Prometheus, OTel) only
	@./scripts/dev/deploy-observability.sh

.PHONY: dev-deploy
dev-deploy: ## Deploy application only (assumes image exists in registry)
	@export KUBECONFIG=$(KUBECONFIG_PATH) && \
		./scripts/dev/build-and-deploy.sh --deploy-only --service '$(SERVICE)'

# ============================================================================
# Testing Commands
# ============================================================================

.PHONY: dev-test
dev-test: ## Run integration tests against Kind cluster
	@export KUBECONFIG=$(KUBECONFIG_PATH) && \
		cargo test -- --ignored --nocapture

# ============================================================================
# Kafka Event Source Commands (conditional)
# ============================================================================

.PHONY: kafka-send-event
kafka-send-event: ## Send a test event to Kafka topic
	@./scripts/dev/send-kafka-event.sh "Test event from make target"

.PHONY: kafka-create-topic
kafka-create-topic: ## Create a new Kafka topic (usage: make kafka-create-topic TOPIC=my-topic)
	@TOPIC="${TOPIC}" && \
	if [ -z "$$TOPIC" ]; then \
		echo "${RED}Error: TOPIC variable required${NC}"; \
		echo "Usage: make kafka-create-topic TOPIC=my-topic"; \
		exit 1; \
	fi && \
	./scripts/dev/create-kafka-topic.sh $$TOPIC

.PHONY: kafka-list-topics
kafka-list-topics: ## List all Kafka topics
	@export KUBECONFIG=$(KUBECONFIG_PATH) && \
	kubectl -n kafka exec -it kafka-0 -- kafka-topics \
		--bootstrap-server localhost:9092 \
		--list

.PHONY: kafka-consumer-lag
kafka-consumer-lag: ## Show consumer group lag (SERVICE=<slug>)
	@export KUBECONFIG=$(KUBECONFIG_PATH) && \
		CONSUMER_GROUP='$(KAFKA_CONSUMER_GROUP)' && \
		kubectl -n kafka exec -it kafka-0 -- kafka-consumer-groups \
		--bootstrap-server localhost:9092 \
		--describe \
		--group $$CONSUMER_GROUP

.PHONY: kafka-logs
kafka-logs: ## View Kafka broker logs
	@export KUBECONFIG=$(KUBECONFIG_PATH) && \
	kubectl logs -n kafka -l app=kafka --tail=100 -f

.PHONY: kafka-source-status
kafka-source-status: ## Check KafkaSource status (SERVICE=<slug>)
	@export KUBECONFIG=$(KUBECONFIG_PATH) && \
		kubectl get kafkasource -n default '$(KAFKA_SOURCE_NAME)' -o yaml

.PHONY: kafka-dlq-logs
kafka-dlq-logs: ## View Dead Letter Queue handler logs (SERVICE=<slug>)
	@export KUBECONFIG=$(KUBECONFIG_PATH) && \
		kubectl logs -f -l serving.knative.dev/service='$(DLQ_SERVICE_NAME)' -c user-container 2>/dev/null || \
		echo "${RED}DLQ handler not running or no events failed${NC}"

# ============================================================================
# PostgreSQL Commands (conditional on feature_postgres; guards fail cleanly
# in generated projects where the feature is off)
# ============================================================================

.PHONY: dev-postgres
dev-postgres: ## Deploy PostgreSQL cluster (requires feature_postgres)
	@if [ ! -f scripts/dev/deploy-postgres.sh ]; then \
		echo "${RED}PostgreSQL feature is not enabled in this project${NC}"; exit 1; \
	fi
	@./scripts/dev/deploy-postgres.sh dev --kustomize deploy/dev/app-overlay

.PHONY: dev-postgres-status
dev-postgres-status: ## Show CNPG Cluster status and ready instances
	@export KUBECONFIG=$(KUBECONFIG_PATH) && ./scripts/dev/check-postgres-status.sh

.PHONY: dev-postgres-port-forward
dev-postgres-port-forward: ## Port-forward <cluster>-rw to localhost:5432
	@export KUBECONFIG=$(KUBECONFIG_PATH) && ./scripts/dev/port-forward-postgres.sh

.PHONY: dev-postgres-psql
dev-postgres-psql: ## Shell into the primary pod's psql (SERVICE selects its database)
	@export KUBECONFIG=$(KUBECONFIG_PATH) && \
		POD=$$(kubectl get pod -n default -o name -l cnpg.io/cluster='$(PROJECT_NAME)-postgres' -l cnpg.io/instanceRole=primary 2>/dev/null | head -1) && \
		if [ -z "$$POD" ]; then \
			echo "${RED}PostgreSQL cluster '$(PROJECT_NAME)-postgres' not found or not ready${NC}"; \
			exit 1; \
		fi && \
		echo "${GREEN}Connecting to $$POD (db: $(POSTGRES_DB), user: app)...${NC}" && \
		kubectl exec -it $$POD -n default -- psql -U app -d '$(POSTGRES_DB)'

.PHONY: validate-postgres
validate-postgres: ## Validate PostgreSQL manifests (requires feature_postgres)
	@./scripts/validate-postgres-manifests.sh

# ============================================================================
# Utility Commands
# ============================================================================

.PHONY: dev-clean
dev-clean: local-down ## Clean everything (alias for local-down)

.PHONY: dev-reset
dev-reset: local-down local-up ## Nuclear option - delete and recreate everything

.PHONY: dev-kubeconfig
dev-kubeconfig: ## Show kubeconfig export command
	@echo "export KUBECONFIG=$(PWD)/$(KUBECONFIG_PATH)"

.PHONY: dev-get-url
dev-get-url: ## Get the application URL (SERVICE=<slug>)
	@export KUBECONFIG=$(KUBECONFIG_PATH) && \
		if kubectl get ksvc '$(SERVICE)' -n default >/dev/null 2>&1; then \
			kubectl get ksvc '$(SERVICE)' -n default -o jsonpath='{.status.url}'; echo; \
		elif kubectl get service '$(SERVICE)' -n default >/dev/null 2>&1; then \
			echo "${YELLOW}'$(SERVICE)' uses a Deployment workload (no Knative URL).${NC}"; \
			kubectl get service '$(SERVICE)' -n default; \
		else \
			echo "${RED}Application '$(SERVICE)' not found${NC}"; \
		fi

# ============================================================================
# FluxCD Bootstrap & Deploy Commands
# ============================================================================

# Valid overlay environments (derived from deploy/overlays/ subdirectories)
VALID_ENVS := $(notdir $(wildcard deploy/overlays/*))

# Bootstrap renders each Flux config with `kustomize build --load-restrictor=LoadRestrictionsNone` (kubectl apply -k cannot set the restrictor) because every config dir references `../../kustomization-<env>.yaml` outside its own root, which kustomize's default LoadRestrictionsRootOnly rejects.
.PHONY: bootstrap
bootstrap: ## Bootstrap Flux resources (usage: make bootstrap [environment])
	@ENV="$(word 2,$(MAKECMDGOALS))"; \
	export KUBECONFIG="$${KUBECONFIG:-$(CLUSTER_KUBECONFIG)}"; \
	if [ -z "$$ENV" ]; then \
		echo "${BLUE}Applying Flux GitRepository...${NC}"; \
		kubectl apply --server-side -f deploy/flux/git-repository.yaml || { echo "${RED}✗ Failed to apply GitRepository${NC}"; exit 1; }; \
		echo ""; \
		echo "${GREEN}✓ GitRepository applied${NC}"; \
		echo ""; \
		echo "${YELLOW}Next:${NC} bootstrap an environment:"; \
		echo "  ${GREEN}make bootstrap production${NC}"; \
		echo "  ${GREEN}make bootstrap staging${NC}"; \
		echo "  ${GREEN}make bootstrap dev${NC}"; \
	else \
		RESOLVED=$$(echo "$$ENV" | sed 's/^production$$/prod/' | sed 's/^development$$/dev/'); \
		CONFIG="deploy/flux/config/$${RESOLVED}"; \
		if [ ! -d "$$CONFIG" ]; then \
			echo "${RED}✗ Unknown environment: $$ENV${NC}"; \
			echo "  Available: $(VALID_ENVS) (also: production, development)"; \
			exit 1; \
		fi; \
		echo "${BLUE}Bootstrapping Flux for environment: $${RESOLVED}${NC}"; \
		echo ""; \
		echo "${YELLOW}[1/2]${NC} Applying GitRepository..."; \
		kubectl apply --server-side -f deploy/flux/git-repository.yaml || { echo "${RED}✗ Failed to apply GitRepository${NC}"; exit 1; }; \
		echo ""; \
		echo "${YELLOW}[2/2]${NC} Applying Flux Kustomizations from $$CONFIG ..."; \
		kustomize build --load-restrictor=LoadRestrictionsNone "$$CONFIG" > /tmp/flux-config-render.yaml && kubectl apply --server-side -f /tmp/flux-config-render.yaml || { echo "${RED}✗ Failed to apply $$CONFIG${NC}"; exit 1; }; \
		echo ""; \
		echo "${GREEN}✓ Flux bootstrap complete for $${RESOLVED}${NC}"; \
		echo "  Flux will now reconcile deploy/overlays/$${RESOLVED}/"; \
	fi

.PHONY: git-auth
git-auth: ## Create the Flux SSH deploy-key Secret for private repositories
	@./scripts/bootstrap-git-auth.sh

# deploy moves the working tree to git and lets Flux take over: it commits,
# pushes, then applies the GitRepository + Kustomizations for the environment
# (the same apply as `make bootstrap <env>`; a no-op after the first run).
.PHONY: deploy
deploy: ## Commit + push, then (re)apply Flux for an environment (usage: make deploy <env>)
	@ENV="$(word 2,$(MAKECMDGOALS))"; \
	if [ -z "$$ENV" ]; then \
		echo "${RED}✗ Usage: make deploy <environment>  (one of: $(VALID_ENVS))${NC}"; \
		exit 1; \
	fi; \
	RESOLVED=$$(echo "$$ENV" | sed 's/^production$$/prod/' | sed 's/^development$$/dev/'); \
	if [ ! -d "deploy/flux/config/$$RESOLVED" ]; then \
		echo "${RED}✗ Unknown environment: $$ENV${NC}"; \
		echo "  Available: $(VALID_ENVS) (also: production, development)"; \
		exit 1; \
	fi; \
	echo "${BLUE}Committing working tree ($$RESOLVED)...${NC}"; \
	git add -A; \
	if git diff --cached --quiet; then \
		echo "${GREEN}✓ Nothing to commit${NC}"; \
	else \
		git commit -m "chore(deploy): sync working tree for $${RESOLVED}" || { echo "${RED}✗ git commit failed (is user.name/user.email configured?)${NC}"; exit 1; }; \
		echo "${GREEN}✓ Committed${NC}"; \
	fi; \
	if git remote get-url origin >/dev/null 2>&1; then \
		git push || { echo "${RED}✗ git push failed${NC}"; exit 1; }; \
		echo "${GREEN}✓ Pushed${NC}"; \
	else \
		echo "${YELLOW}⚠ No 'origin' remote — skipping push; Flux only sees committed AND pushed changes.${NC}"; \
	fi; \
	$(MAKE) bootstrap "$$RESOLVED"

# No-op targets for bootstrap/deploy environment arguments
# These prevent Make from erroring on "make deploy production" etc.
.PHONY: dev staging prod production development
dev staging prod production development:
	@:
