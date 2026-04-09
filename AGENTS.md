# Agent Guidelines for Rust Knative Flux Template

This document provides essential information for AI coding agents working in this repository.

## Build, Lint, and Test Commands

### Building
```bash
# Development build
cargo build

# Production build (optimized)
cargo build --release

# Build for musl target (matches Docker)
cargo build --release --target x86_64-unknown-linux-musl

# Check compilation without building
cargo check
```

### Linting and Formatting
```bash
# Format all code (required before commits)
cargo fmt --all

# Check formatting without applying
cargo fmt --all -- --check

# Run Clippy with strict warnings
cargo clippy --all-targets --all-features -- -D warnings

# Auto-fix Clippy suggestions where possible
cargo clippy --fix --allow-dirty --allow-staged
```

### Testing
```bash
# Run all tests
cargo test

# Run all tests with verbose output
cargo test -- --nocapture

# Run a single test by name
cargo test test_liveness_endpoint

# Run tests matching a pattern
cargo test health

# Run tests in a specific file
cargo test --test health_test

# Run with all features enabled
cargo test --all-features

# Run ignored tests (like integration tests)
cargo test -- --ignored

# Run specific test with output
cargo test test_readiness_endpoint -- --nocapture --test-threads=1
```

### Development Workflow
```bash
# Start local development environment (Kind + Knative + all services)
make dev-up

# Watch for changes and re-run tests
cargo watch -x test

# Rebuild and redeploy application after changes
make dev-restart

# View application logs
make dev-logs

# Stop development environment
make dev-down
```

## Naming Conventions

### Project Name Handling

The template uses consistent naming conventions across Rust code, Kubernetes resources, and Docker images:

**Key Principle**: Kubernetes and Docker require hyphens, Rust prefers underscores. The template normalizes this during generation.

#### Template Generation (cargo-generate)

When generating a project, the template automatically handles naming:

- **User input** (project_name): Can use any format
  - `"my-service"` (hyphens)
  - `"my_service"` (underscores)
  - `"myservice"` (single word)

- **Generated names**:
  - **Cargo.toml crate name** (`crate_name`): Automatically converted to snake_case (underscores)
    - Example: `"my_service"`, `"myservice"`
    - Used in: Binary names, Rust module paths, internal code
  
  - **Kubernetes service name** (`project_name | replace: "_", "-"`): Normalized to kebab-case (hyphens)
    - Example: `"my-service"`, `"myservice"`
    - Used in: Knative service names, Docker image tags, K8s resource labels
    - **Critical**: Knative services CANNOT contain underscores - violations cause `ImagePullBackOff` errors

#### Template Files

Files that handle name normalization:

- **Makefile.liquid**: Templated with `PROJECT_NAME` (hyphens) and `CRATE_NAME` (underscores)
  - `PROJECT_NAME := {{ project_name | replace: "_", "-" }}`
  - `CRATE_NAME := {{ crate_name }}`

- **scripts/dev/build-and-deploy.sh.liquid**: Hardcoded service and binary names at generation time
  - `SERVICE_NAME="{{ project_name | replace: "_", "-" }}"`  (for Docker tags, Kubernetes)
  - `CRATE_NAME="{{ crate_name }}"`  (for binary verification)

- **deploy/base/knative-service.yaml.liquid**: Uses `{{ project_name | replace: "_", "-" }}` for service name
  - `name: {{ project_name | replace: "_", "-" }}`

#### Common Issues and Solutions

**Issue**: `ImagePullBackOff` when deploying to Knative
- **Cause**: Image tag name doesn't match Knative service name (usually underscores vs hyphens)
- **Solution**: Ensure templated scripts use `PROJECT_NAME` for Kubernetes and `CRATE_NAME` for Rust

**Issue**: Docker image tag doesn't match Kustomization reference
- **Cause**: Build script extracts name from Cargo.toml at runtime (gets underscores), but Kustomization expects hyphens
- **Solution**: Use templated build script that has names baked in at generation time

**Issue**: Knative service won't start with name containing underscores
- **Cause**: Knative spec forbids underscores in service names
- **Solution**: Always use hyphens in Kubernetes resource names (automatic with this template)

#### Testing Naming Conventions

Run the naming convention e2e tests to verify correct behavior:

```bash
# GitHub Actions workflow tests all naming styles:
# - kebab-case: test-service
# - snake_case: test_service
# - single-word: testservice

# Tests verify:
# ✓ Crate name matches Cargo.toml
# ✓ Knative service name uses hyphens (no underscores)
# ✓ Docker image tag uses hyphens
# ✓ Makefile PROJECT_NAME uses hyphens
# ✓ Build script correctly handles SERVICE_NAME and CRATE_NAME
```

#### Why This Matters

This naming normalization prevents a critical class of deployment failures:

1. **Kubernetes Constraint**: Service names must match DNS subdomain rules (`[a-z0-9]([-a-z0-9]*[a-z0-9])?`)
   - Hyphens are allowed, underscores are NOT

2. **Docker Convention**: Image tags should use hyphens for consistency
   - Underscores work but violate conventions

3. **Rust Convention**: Crate names use underscores in Cargo.toml
   - This is the Rust package naming standard

The template bridges these conventions so generated projects work seamlessly across all layers.

## Code Style Guidelines

### File Organization
- **Modules**: Organize by domain (handlers/, config.rs, state.rs, error.rs, observability.rs)
- **One module per file**: Use `mod.rs` for public re-exports
- **lib.rs**: Public API exports; main.rs is application entry point only

### Import Style
```rust
// Standard library
use std::sync::Arc;
use std::time::Duration;

// External crates (alphabetical)
use axum::{extract::State, Json};
use serde::{Deserialize, Serialize};
use tokio::signal;

// Internal modules (relative or crate-level)
use crate::config::Config;
use crate::error::AppError;
use crate::state::AppState;
```

### Naming Conventions
- **Types**: `PascalCase` (e.g., `AppState`, `HealthResponse`)
- **Functions**: `snake_case` (e.g., `create_router`, `init_telemetry`)
- **Constants**: `SCREAMING_SNAKE_CASE` (e.g., `MAX_RETRIES`)
- **Lifetimes**: Short, descriptive (e.g., `'a`, `'static`)
- **Generic types**: Single uppercase letter or descriptive (e.g., `T`, `TState`)

### Type Usage
```rust
// Always use explicit types for public APIs
pub fn process_data(input: &str) -> Result<String, AppError> { }

// Use Option<T> for optional values, never null-like patterns
pub struct Config {
    pub name: Option<String>,  // Good
}

// Use Result<T, E> for fallible operations
pub async fn connect() -> Result<Connection, AppError> { }

// Derive common traits where applicable
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct User {
    pub id: String,
}
```

### Error Handling
```rust
// Use thiserror for custom error types
#[derive(Error, Debug)]
pub enum AppError {
    #[error("Redis error: {0}")]
    Redis(#[from] redis::RedisError),
    
    #[error("Configuration error: {0}")]
    Config(String),
}

// Propagate errors with ? operator
pub async fn fetch_data() -> Result<Data, AppError> {
    let conn = connect().await?;
    let data = conn.get("key").await?;
    Ok(data)
}

// Log errors before returning
tracing::error!(error = %e, "Failed to connect");
Err(AppError::Internal(e.to_string()))

// Never use .unwrap() or .expect() in production code
// Use proper error handling or provide safe defaults
```

### Documentation
```rust
/// Brief one-line description
///
/// Longer description with more context.
///
/// # Arguments
///
/// * `key` - Description of parameter
/// * `data` - Description of parameter
///
/// # Returns
///
/// Returns `Ok(())` on success, `Err(AppError)` on failure
///
/// # Errors
///
/// Returns error if connection fails or timeout occurs
///
/// # Example
///
/// ```ignore
/// let result = upload_file("key", &data).await?;
/// ```
pub async fn upload_file(key: &str, data: &[u8]) -> Result<(), AppError> {
    // Implementation
}
```

### Async/Await Patterns
```rust
// Use async for I/O operations (network, file, database)
pub async fn fetch_user(id: &str) -> Result<User, AppError> { }

// Don't use async for pure computation
pub fn calculate_hash(data: &[u8]) -> String { }

// Use tokio::spawn for concurrent tasks
let handle = tokio::spawn(async move {
    process_data().await
});
```

### Axum Handler Patterns
```rust
// Use State extractor for shared state
pub async fn handler(
    State(state): State<AppState>,
    Json(payload): Json<Request>,
) -> Result<Json<Response>, AppError> {
    // Handler logic
    Ok(Json(response))
}

// Return Results, implement IntoResponse for custom errors
impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        // Convert error to HTTP response
    }
}
```

### Observability Patterns
```rust
// Use structured logging with tracing
tracing::info!(user_id = %id, "Processing user request");
tracing::error!(error = %e, "Operation failed");

// Add OpenAPI documentation to handlers
#[utoipa::path(
    get,
    path = "/api/v1/users/{id}",
    tag = "Users",
    responses(
        (status = 200, description = "Success", body = User),
        (status = 404, description = "Not found")
    )
)]
pub async fn get_user(/* ... */) -> Result<Json<User>, AppError> { }
```

### Instrumentation with #[instrument]

Use the `#[instrument]` macro from `tracing` to automatically create spans for function entry/exit:

```rust
use tracing::instrument;

// Basic usage - auto-captures function name and parameters
#[instrument]
pub async fn process_data(id: String) -> Result<Data, AppError> {
    // Span created automatically
}

// Skip complex parameters (State, large structs)
#[instrument(skip(state, event))]
pub async fn handler(
    State(state): State<AppState>,
    event: CloudEvent<T>,
) -> Result<Response, AppError> { }

// Extract specific fields from complex parameters
#[instrument(
    skip(event),
    fields(
        event_id = %event.id(),
        event_type = %event.r#type()
    )
)]
pub async fn handle_event(event: CloudEvent<T>) -> Response { }

// Set custom trace level (default: info)
#[instrument(level = "debug")]
pub async fn health_check() -> bool { }

// Auto-log errors on Result::Err
#[instrument(err)]
pub async fn fallible_operation() -> Result<T, AppError> { }

// Record computed values in span
#[instrument(fields(computed_key = tracing::field::Empty))]
pub async fn storage_op() -> Result<(), AppError> {
    let key = generate_key();
    tracing              tracing::Span::current().record("computed_key", &key.as_str());
    // ...
}
```

**When to use `#[instrument]`:**
- ✅ All public async functions (handlers, business logic)
- ✅ Functions that represent logical operations
- ✅ Any function you'd manually add entry/exit logging to

**When NOT to use `#[instrument]`:**
- ❌ `main()` and application lifecycle functions
- ❌ Pure synchronous utility functions (unless complex)
- ❌ Functions called in tight loops (performance impact)
- ❌ Test functions

**Keep explicit `tracing::` calls for:**
- Progress logging within a function (debug/info events)
- Error logging with additional context
- Business-significant events (not just function entry/exit)

## Testing Patterns

```rust
// Unit tests in same file
#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_sync_function() {
        assert_eq!(add(2, 2), 4);
    }
    
    #[tokio::test]
    async fn test_async_function() {
        let result = async_operation().await;
        assert!(result.is_ok());
    }
}

// Integration tests in tests/ directory
#[tokio::test]
async fn test_endpoint() {
    let state = common::create_test_state().await;
    let app = routes::create_router(state);
    let server = TestServer::new(app).unwrap();
    
    let response = server.get("/health/live").await;
    assert_eq!(response.status_code(), 200);
}
```

## Kafka Event Publishing Patterns

When Kafka event publishing is enabled (`enable_kafka_publishing = true`), use these patterns:

### Non-Blocking Event Publishing from Handlers

Publish events asynchronously without blocking HTTP responses:

```rust
use std::sync::Arc;

pub async fn my_handler(
    State(state): State<AppState>,
    Json(payload): Json<MyRequest>,
) -> Json<MyResponse> {
    // Handle the request
    let response = MyResponse { /* ... */ };

    // Publish event to Kafka (non-blocking via tokio::spawn)
    if let Some(publisher) = &state.kafka_publisher {
        let publisher = Arc::clone(publisher);
        let broker_url = publisher.config.broker_url.clone();
        let topic = publisher.config.topic.clone();

        tokio::spawn(async move {
            let event = crate::handlers::kafka::create_dummy_event(
                &publisher.config,
                "/api/v1/my-handler"
            );
            let event_id = event.id().to_string();

            match publisher.publish(&event).await {
                Ok((partition, offset)) => {
                    tracing::debug!(
                        event_id = %event_id,
                        partition = partition,
                        offset = offset,
                        "Event published"
                    );
                }
                Err(e) => {
                    let (error_type, error_context) = e.context();
                    tracing::error!(
                        error = %e,
                        error_type = %error_type,
                        error_context = %error_context,
                        event_id = %event_id,
                        broker = %broker_url,
                        topic = %topic,
                        "Failed to publish event"
                    );
                    // Note: HTTP response already sent, error logged for monitoring
                }
            }
        });
    }

    // Return 200 OK immediately, regardless of event publishing result
    Json(response)
}
```

### Distributed Tracing for Event Publishing

The `KafkaPublisher::publish()` method is instrumented with:

```rust
#[tracing::instrument(
    skip(self, event),
    fields(
        event_id = %event.id(),
        topic = %self.config.topic,
        event_type = %event.type_(),
        source = %event.source()
    ),
    err(Debug)
)]
pub async fn publish(&self, event: &CloudEvent) -> Result<(i32, i64), KafkaError> {
    // Implementation...
}
```

This automatically creates spans with:
- **event_id**: Unique event identifier (searchable in Jaeger)
- **topic**: Kafka topic name
- **event_type**: CloudEvents type
- **source**: Handler path or source
- **partition** & **offset**: Added on success for audit trails
- **error details**: Captured on failure for debugging

View in Jaeger by searching for operation name `KafkaPublisher::publish`.

### Error Handling Patterns

Always handle publishing errors gracefully:

```rust
// Pattern 1: Log and ignore (safe for non-critical events)
match publisher.publish(&event).await {
    Ok(_) => tracing::info!("Event published"),
    Err(e) => {
        let (error_type, ctx) = e.context();
        tracing::warn!(error_type, error_context = ctx, "Event publish failed");
        // Handler continues normally - user gets 200 OK
    }
}

// Pattern 2: Log with context for monitoring
if let Err(e) = publisher.publish(&event).await {
    let (error_type, ctx) = e.context();
    tracing::error!(
        error = %e,
        error_type = %error_type,
        error_context = %ctx,
        event_id = %event.id(),
        broker = %publisher.config.broker_url,
        "Critical event publish failed"
    );
    // Alert on repeated failures via metrics
}

// Never block handler on publishing errors
// Handler always returns 200 OK (event delivery is best-effort)
```

### Prometheus Metrics for Event Publishing

Metrics are automatically recorded by `KafkaPublisher`:

```rust
// Query success rate
rate(kafka_events_published_total{topic="your-topic"}[5m])

// Query failure rate by type
rate(kafka_events_failed_total{topic="your-topic", error_type="broker_unreachable"}[5m])

// Query latency percentiles
histogram_quantile(0.99, kafka_publish_latency_ms{topic="your-topic"})

// Alert on high failure rate
(rate(kafka_events_failed_total[5m]) / rate(kafka_events_published_total[5m])) > 0.01
```

### Cold Start Impact

Event publishing adds minimal cold start overhead:

- **Kafka producer initialization**: ~100-200ms (happens once at startup)
- **Per-publish latency**: ~10-50ms typical (non-blocking, does not affect HTTP response)
- **Memory overhead**: ~5-10 MB for rdkafka producer

Optimization tips:
- Keep Kafka broker accessible with low latency (<50ms)
- Use SNI/TLS caching for broker connections
- Monitor cold start times in production (`container_runtime_duration_seconds` metric)

### Configuration for Publishing

When generating project, provide:

```
Enable Kafka event publishing? yes
Kafka broker URL: kafka.example.com:9092
Kafka topic name: my-service-events
CloudEvents event name: com.example.myservice.event.published
```

These configure:
- `broker_url`: Kafka broker address for publishing
- `topic`: Kafka topic where events are sent
- `event_name`: CloudEvents type field for your events
- `compression`: Snappy (default, adjustable)
- `linger_ms`: 5ms default (batch small messages)
- `timeout_ms`: 10s default (fail-fast on unreachable broker)

## Knative-Specific Constraints

- **Port 8080**: Always use port 8080 (required by Knative)
- **Health checks**: Implement `/health/live` (liveness) and `/health/ready` (readiness)
- **Graceful shutdown**: Handle SIGTERM for zero-downtime deployments
- **Fast startup**: Optimize cold start time (<2 seconds preferred)
- **B3 propagation**: Use B3 headers for distributed tracing (via opentelemetry-zipkin)

## Local Development Image Override

When working with the local development environment, images are built and pushed to a local Docker registry running at `localhost:5001`.

### Image Tagging Convention

- **Development builds**: Use `dev` tag (e.g., `localhost:5001/my-service:dev`)
- **Production builds**: Use `latest` or semantic version tags (e.g., `ghcr.io/org/my-service:1.0.0`)

### Kustomize Image Override Pattern

The dev overlay automatically overrides the GHCR image reference with the local registry:

```yaml
# deploy/overlays/dev/kustomization.yaml
images:
  - name: ghcr.io/org/my-service      # Base image reference
    newName: localhost:5001/my-service # Local registry
    newTag: dev                         # Development tag
```

This allows:
- Base manifests reference production registry (GHCR)
- Dev overlay automatically uses local registry (no GHCR auth needed)
- Staging/prod overlays use production images unchanged
- `make dev-restart` rebuilds and deploys with local image

### Build Process

The `scripts/dev/build-and-deploy.sh` script:
1. Builds Docker image: `docker build -t localhost:5001/my-service:dev .`
2. Pushes to local registry: `docker push localhost:5001/my-service:dev`
3. Applies Kustomize overlay: `kubectl apply -k deploy/overlays/dev`
4. Kustomize substitutes image → Knative pulls from local registry

**No imagePullSecrets needed** for local development!

## Deployment Structure

The template uses a modern Kustomize component-based architecture for deployments:

### Directory Structure

```
deploy/
├── base/                    # Core application manifests
│   └── knative-service.yaml # Only the Knative service (no infra)
├── components/              # Optional feature components (Kustomize Components)
│   ├── operator/           # CloudNativePG operator (local dev only)
│   │   └── kustomization.yaml
│   ├── postgres/           # PostgreSQL cluster resources
│   │   ├── kustomization.yaml
│   │   ├── cluster.yaml
│   │   ├── backup.yaml
│   │   ├── objectstore.yaml
│   │   └── ...
│   └── kafka/              # Kafka event source resources
│       ├── kustomization.yaml
│       ├── kafka-source.yaml
│       └── dlq-handler.yaml
└── overlays/               # Environment-specific configurations
    ├── dev/                # Local development
    │   ├── kustomization.yaml  # Includes: operator, postgres, kafka
    │   └── patches/
    ├── staging/            # Staging environment
    │   ├── kustomization.yaml  # Includes: postgres, kafka (NO operator)
    │   └── patches/
    └── prod/               # Production environment
        ├── kustomization.yaml  # Includes: postgres, kafka (NO operator)
        └── patches/
```

### Component-Based Architecture

**Key Benefits:**
- **Modular**: Features are opt-in via components
- **Environment-aware**: Dev includes operator, prod/staging assumes pre-installed
- **GitOps-ready**: Components can be selectively enabled in FluxCD Kustomizations
- **Maintainable**: Changes to postgres/kafka isolated to their components

**Usage in Overlays:**

```yaml
# deploy/overlays/dev/kustomization.yaml (Local Development)
components:
  - ../../components/operator   # Install CNPG operator for local dev
  - ../../components/postgres   # Deploy PostgreSQL cluster
  - ../../components/kafka      # Deploy Kafka event source

# deploy/overlays/prod/kustomization.yaml (Production)
components:
  - ../../components/postgres   # Deploy PostgreSQL cluster only
  - ../../components/kafka      # Deploy Kafka event source only
  # NO operator component - assumes cluster-wide operator pre-installed
```

### CNPG Operator Installation

**Critical**: Beyond local development, the CloudNativePG operator should be installed **cluster-wide** via your cluster management tooling (Flux, ArgoCD, Terraform, etc.), not per-application.

- **Local dev (`dev` overlay)**: Includes `components/operator` to install CNPG operator
- **Staging/Prod (`staging`/`prod` overlays)**: Assumes operator already installed, only includes `components/postgres`

This prevents:
- Multiple operator installations (one per namespace)
- Version conflicts between applications
- Unnecessary resource duplication
- Deployment failures when operator CRDs are missing

**For production clusters**, install the operator separately:

```yaml
# Example: FluxCD HelmRelease for cluster-wide operator
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: cloudnative-pg
  namespace: cnpg-system
spec:
  chart:
    spec:
      chart: cloudnative-pg
      sourceRef:
        kind: HelmRepository
        name: cnpg
```

Or via Kustomization:

```yaml
# Example: FluxCD Kustomization for cluster-wide operator
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cnpg-operator
  namespace: flux-system
spec:
  path: ./deploy/infrastructure/cloudnative-pg/operator
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
```

## Configuration

- Use `figment` for hierarchical config (TOML files + env vars)
- Environment variables override TOML config
- Prefix env vars with `APP__` (e.g., `APP__REDIS__URL`)
- Never commit secrets; use Kubernetes secrets

## Commit Message Format

Follow Conventional Commits:
```
<type>(<scope>): <subject>

Types: feat, fix, docs, style, refactor, test, chore
Examples:
  feat(api): add user endpoint
  fix(storage): resolve S3 timeout
  docs(readme): update deployment instructions
```

## Active Technologies
- Rust 1.75+ (existing template), YAML manifests for Kubernetes resources + CloudNativePG Operator 1.28.0 (Kubernetes CRDs), Barman Cloud Plugin (barman-cloud.cloudnative-pg.io), FluxCD for GitOps deploymen (001-cloudnative-postgres-backups)
- PostgreSQL (deployed via CloudNativePG operator), S3-compatible object storage (MinIO for dev, configurable for prod) (001-cloudnative-postgres-backups)
- Flagger >=1.38.0 (optional, `flagger` feature flag), flagger-loadtester >=0.34.0, Knative provider (no service mesh)
- GitHub Actions Runner Controller (ARC) gha-runner-scale-set >=0.13.1 (optional, `feature_gha_runner` flag), Docker-in-Docker sidecar, scale-to-zero

## Flagger Canary Release Promotion

When `feature_flagger` is selected during `cargo generate`, the template adds automated canary release promotion via [Flagger](https://flagger.app).

### Architecture

```
FluxCD GitRepository
  └── FluxCD Kustomization (flagger)
        └── deploy/infrastructure/flagger/operator/
              ├── namespace.yaml           # flagger-system namespace
              ├── helmrepository.yaml      # flagger.app Helm repo
              └── helmrelease.yaml         # Flagger operator + loadtester

FluxCD Kustomization (app) dependsOn (flagger)
  └── deploy/overlays/staging|prod/
        └── components/flagger/            # Kustomize Component
              ├── canary.yaml              # Canary CRD (wraps KnativeService)
              └── metric-templates.yaml    # Prometheus MetricTemplate CRDs
```

### How It Works

1. **Developer pushes** a new image tag; Flux ImageUpdateAutomation updates `knative-service.yaml`
2. **Flux reconciles** — applies the updated KnativeService, creating a new Knative revision
3. **Flagger detects** the new revision and starts canary analysis
4. **Traffic shifts** 10% → 20% → ... → 50% in 1-minute steps
5. **Metric gates** evaluated each step:
   - HTTP success rate ≥ `canary_success_rate_threshold`% (default 99%)
   - p99 latency ≤ `canary_latency_threshold_ms`ms (default 500ms)
   - Custom app metric ≥ 0 (placeholder — fill in with your business KPI)
6. **Promotion**: after 5 passing steps at maxWeight (50%), Flagger shifts 100% to the new revision
7. **Rollback**: if any metric gate fails `threshold` (5) consecutive times, Flagger rolls back to the primary revision and fires an alert

### Template Variables

| Variable | Default | Description |
|---|---|---|
| `canary_success_rate_threshold` | `99` | Min HTTP success rate % |
| `canary_latency_threshold_ms` | `500` | Max p99 latency in ms |

### Operator Installation

Flagger is cluster-wide — install once via `deploy/flux/flagger-kustomization.yaml`.
The app FluxCD Kustomization should declare `dependsOn: [{name: flagger}]` to ensure
CRDs exist before Canary objects are applied.

**Do NOT install Flagger per-application namespace** — it will conflict with an existing
cluster-wide installation.

### Monitoring Canary Progress

```bash
# Watch canary status in real time
kubectl describe canary <service-name> -n <namespace>

# Check Flagger logs
kubectl logs -n flagger-system deploy/flagger -f

# Check load tester
kubectl logs -n flagger-system deploy/flagger-loadtester -f

# Manually pause a canary (halts traffic shifting until resumed)
kubectl annotate canary/<service-name> flagger.app/canary.paused="true" -n <namespace>

# Resume a paused canary
kubectl annotate canary/<service-name> flagger.app/canary.paused- -n <namespace>
```

### Customizing Metric Gates

Edit `deploy/components/flagger/metric-templates.yaml` to:
- Change the Prometheus address (default: `http://prometheus.observability.svc.cluster.local:9090`)
- Update the custom metric PromQL query with your business KPI
- Add additional MetricTemplates for extra gates

Edit `deploy/components/flagger/canary.yaml` to:
- Adjust `stepWeight` (default 10%), `maxWeight` (default 50%), `interval` (default 1m)
- Change `threshold` (default 5 consecutive failures before rollback)
- Add/remove metric gates
- Configure notification webhooks (Slack, PagerDuty, etc.)

### File Structure

```
deploy/
├── components/flagger/
│   ├── kustomization.yaml       # Kustomize Component declaration
│   ├── canary.yaml              # Flagger Canary CRD
│   └── metric-templates.yaml   # Prometheus MetricTemplate CRDs
├── infrastructure/flagger/
│   └── operator/
│       ├── kustomization.yaml   # References namespace + helmrepository + helmrelease
│       ├── namespace.yaml       # flagger-system namespace
│       ├── helmrepository.yaml  # flagger.app Helm chart repository
│       └── helmrelease.yaml     # Flagger + loadtester HelmReleases
└── flux/
    └── flagger-kustomization.yaml  # FluxCD Kustomization for the operator
```

## GitHub Actions Self-Hosted Runner (ARC Scale Set)

When `feature_gha_runner` is selected during `cargo generate`, the template adds a per-repo self-hosted runner via [ARC (Actions Runner Controller)](https://github.com/actions/actions-runner-controller) `gha-runner-scale-set` Helm chart.

### Architecture

```
FluxCD GitRepository
  └── FluxCD Kustomization (runner) dependsOn (actions-runner-controller)
        └── deploy/infrastructure/gha-runner/
              ├── oci-repository.yaml   # OCI source for ARC scale set chart
              └── helmrelease.yaml      # Runner scale set HelmRelease
```

### How It Works

1. ARC controller (cluster-wide, pre-installed) watches for `AutoScalingRunnerSet` CRDs
2. The HelmRelease creates an `AutoScalingRunnerSet` bound to `githubConfigUrl` (this repo)
3. ARC listener monitors GitHub for `workflow_job` events targeting this runner label
4. On workflow trigger: ARC scales from 0 → N runner pods (up to `maxRunners`)
5. Each runner pod includes a Docker-in-Docker sidecar for container builds
6. After job completion: pods terminate, scale back to 0

### Prerequisites

The ARC controller operator must be installed cluster-wide **before** deploying the runner scale set. The Flux Kustomization declares `dependsOn: [{name: actions-runner-controller}]`.

A `github-auth-secret` Kubernetes Secret must exist in `actions-runner-system` namespace with a GitHub App or PAT for runner registration.

### Template Variables

| Variable | Default | Description |
|---|---|---|
| `gha_runner_chart_version` | `0.13.1` | ARC runner scale set chart version |
| `gha_runner_image_tag` | `2.331.0` | GitHub Actions runner image tag |
| `gha_runner_max` | `4` | Maximum concurrent runners |
| `gha_runner_storage_class` | `openebs-hostpath` | StorageClass for work volume |
| `gha_runner_priority_class` | `actions-runner-high-priority` | PriorityClass for runner pods |
| `gha_runner_storage_size` | `50Gi` | Work volume size |

### Resource Defaults

| Container | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---|---|---|---|---|
| runner | 2 | 2 | 8Gi | 8Gi |
| dind | 2 | 2 | 8Gi | 8Gi |
| listener | 100m | 100m | 128Mi | 128Mi |

### Using in CI Workflows

Reference the runner in `.github/workflows/*.yaml`:

```yaml
jobs:
  build:
    runs-on: <project-name>-runner
```

The `runnerScaleSetName` is set to `<project-name>-runner`, matching the HelmRelease name.

### File Structure

```
deploy/
├── infrastructure/gha-runner/
│   ├── kustomization.yaml     # References oci-repository + helmrelease
│   ├── oci-repository.yaml    # OCI source for ARC chart from ghcr.io
│   └── helmrelease.yaml       # Runner scale set with DinD sidecar
└── flux/
    └── gha-runner-kustomization.yaml  # FluxCD Kustomization, dependsOn ARC controller
```

## Recent Changes
- 001-cloudnative-postgres-backups: Added Rust 1.75+ (existing template), YAML manifests for Kubernetes resources + CloudNativePG Operator 1.28.0 (Kubernetes CRDs), Barman Cloud Plugin (barman-cloud.cloudnative-pg.io), FluxCD for GitOps deploymen
- flagger-canary: Added opt-in Flagger canary release promotion with Knative provider, Prometheus metric gates (success rate + p99 latency + custom), and FluxCD HelmRelease operator lifecycle management
- gha-runner: Added opt-in per-repo GitHub Actions self-hosted runner (ARC gha-runner-scale-set) with Docker-in-Docker sidecar, scale-to-zero, and FluxCD lifecycle management
