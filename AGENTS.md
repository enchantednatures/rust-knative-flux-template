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

## Recent Changes
- 001-cloudnative-postgres-backups: Added Rust 1.75+ (existing template), YAML manifests for Kubernetes resources + CloudNativePG Operator 1.28.0 (Kubernetes CRDs), Barman Cloud Plugin (barman-cloud.cloudnative-pg.io), FluxCD for GitOps deploymen
