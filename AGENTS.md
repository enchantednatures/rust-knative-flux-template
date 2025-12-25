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
# Watch for changes and re-run tests
cargo watch -x test

# Watch and re-run specific test
cargo watch -x "test test_liveness_endpoint"

# Start local services for testing
docker-compose up -d

# Stop local services
docker-compose down
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
