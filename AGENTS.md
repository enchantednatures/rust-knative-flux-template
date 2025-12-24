# Agent Development Guide

This guide provides coding agents with essential commands, code style guidelines, and conventions for working in this Rust Knative/FluxCD template repository.

## Build, Test, and Lint Commands

### Building
```bash
# Development build
cargo build

# Production build (optimized)
cargo build --release

# Build for Alpine/musl target
cargo build --release --target x86_64-unknown-linux-musl

# Build Docker image
docker build -t app:latest .
```

### Testing
```bash
# Run all tests
cargo test

# Run all tests with output
cargo test -- --nocapture

# Run a single test by name
cargo test test_liveness_endpoint

# Run a specific test file
cargo test --test health_test

# Run tests with Redis/MinIO services
docker-compose up -d && cargo test

# Run integration tests only
cargo test --test '*'

# Run tests single-threaded (for tests requiring exclusive resource access)
cargo test -- --test-threads=1
```

### Linting and Formatting
```bash
# Format code (required before commit)
cargo fmt

# Check formatting without modifying files
cargo fmt --all -- --check

# Lint with clippy (zero warnings required)
cargo clippy --all-targets --all-features -- -D warnings

# Quick clippy check
cargo clippy

# Check without building
cargo check
```

### Documentation
```bash
# Generate and open documentation
cargo doc --no-deps --open

# Check documentation for broken links
cargo doc --no-deps
```

### Development Workflow
```bash
# Watch for changes and auto-run (requires cargo-watch)
cargo watch -q -c -w src -x run

# Auto-run tests on change
cargo watch -x test

# Run locally with services
docker-compose up -d
export APP__REDIS__URL=redis://localhost:6379
cargo run
```

## Code Style Guidelines

### Imports Organization
Organize imports in this order:
1. Standard library (`std::`, `core::`)
2. External crates (alphabetically)
3. Internal crate modules (`crate::`)

**Example:**
```rust
use axum::{
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

use crate::state::AppState;
```

### Formatting
- **Line length**: 100 characters (rustfmt default)
- **Indentation**: 4 spaces (enforced by rustfmt)
- **Trailing commas**: Required in multi-line expressions
- Use `cargo fmt` before every commit

### Naming Conventions
- **Types**: `PascalCase` (structs, enums, traits)
- **Functions/methods**: `snake_case`
- **Constants**: `SCREAMING_SNAKE_CASE`
- **Modules**: `snake_case`
- **Generics**: Single uppercase letter (`T`, `E`) or descriptive (`TState`)

**Examples:**
```rust
pub struct AppState { }              // Type
pub async fn readiness() { }         // Function
const MAX_RETRIES: u32 = 3;          // Constant
mod handlers;                         // Module
fn process<T>(item: T) { }           // Generic
```

### Types and Safety
- **No unwrap/expect**: Use `?` operator or proper error handling with `Result`
- **Use thiserror for errors**: Define custom error types with `#[derive(Error)]`
- **Explicit types**: Prefer explicit return types on public functions
- **Option/Result**: Use combinators (`map`, `and_then`, `unwrap_or_else`) over pattern matching where appropriate

**Error Handling Example:**
```rust
// BAD - uses unwrap
let conn = redis_client.get_connection().unwrap();

// GOOD - proper error propagation
let conn = redis_client.get_connection()?;

// GOOD - error context
let conn = redis_client.get_connection()
    .map_err(|e| {
        tracing::error!(error = %e, "Failed to connect to Redis");
        e
    })?;
```

### Async/Await
- Always use `async`/`.await` syntax (not `futures::executor`)
- Use `tokio::spawn` for concurrent tasks
- Prefer `tokio::select!` for cancellation and timeouts

### Documentation
- **Public APIs**: Require doc comments (`///`)
- **Modules**: Add module-level docs (`//!`)
- **Examples**: Include code examples in doc comments when helpful
- **Panics/Errors**: Document panic conditions and error cases

**Example:**
```rust
/// Readiness probe - can the service handle traffic?
///
/// Checks Redis connectivity with PING before returning 200 OK.
/// If Redis is unreachable, returns 503 Service Unavailable.
///
/// Kubernetes will remove the pod from Service endpoints if this fails,
/// but will NOT restart the pod.
#[utoipa::path(
    get,
    path = "/health/ready",
    tag = "Health",
    responses(
        (status = 200, description = "Service is ready", body = HealthResponse),
        (status = 503, description = "Service unavailable", body = HealthResponse)
    )
)]
pub async fn readiness(
    State(state): State<AppState>,
) -> Result<Json<HealthResponse>, (StatusCode, Json<HealthResponse>)> {
    // Implementation...
}
```

### Project-Specific Patterns

#### 1. Axum Handlers
- Use extractors in function parameters
- Return types implementing `IntoResponse`
- Add `#[utoipa::path]` attributes for OpenAPI docs

```rust
pub async fn handler(
    State(state): State<AppState>,
    Json(payload): Json<RequestPayload>,
) -> Result<Json<Response>, AppError> {
    // Handler logic
}
```

#### 2. State Management
- Access shared state via `State<AppState>` extractor
- Clone Redis connections (they're multiplexed, so cloning is cheap)
- Keep state immutable when possible

#### 3. OpenTelemetry/Tracing
- Use structured logging: `tracing::info!(field = %value, "message")`
- Add spans for significant operations
- Critical: Use B3 propagation for Knative compatibility (already configured)

```rust
tracing::info!(name = %name, "Hello endpoint called");
tracing::error!(error = %e, "Redis health check failed");
```

#### 4. Configuration
- Use `figment` for configuration (TOML files + env vars)
- Prefix env vars with `APP__` (double underscore separator)
- Fail fast on config errors in `main.rs`

#### 5. OpenAPI Documentation
- All public endpoints must have `#[utoipa::path]` attributes
- Add schemas to `ApiDoc` struct in `routes.rs`
- Use `ToSchema` derive for request/response types

#### 6. Error Handling
- Use `AppError` enum for application errors
- Implement `IntoResponse` for custom error types
- Log errors before returning responses

## Architecture Conventions

### File Structure
```
src/
├── main.rs              # Application entry, initialization
├── lib.rs               # Module exports
├── config.rs            # Configuration structs
├── state.rs             # AppState definition
├── error.rs             # Error types
├── observability.rs     # OpenTelemetry setup
├── routes.rs            # Router and route definitions
└── handlers/
    ├── mod.rs           # Handler module exports
    ├── health.rs        # Health check handlers
    └── api.rs           # Business logic handlers
```

### Adding New Endpoints
1. Define handler in `src/handlers/api.rs`
2. Add `#[utoipa::path]` documentation
3. Register route in `src/routes.rs`
4. Add schema types to `ApiDoc` in `routes.rs`
5. Write tests in `tests/` directory

## Knative-Specific Considerations

- **Health checks**: Separate liveness (`/health/live`) and readiness (`/health/ready`)
- **Graceful shutdown**: Handle SIGTERM for Knative termination
- **B3 propagation**: Already configured - don't change `observability.rs` without understanding impact
- **Port**: Default 8080 (configurable via `APP__SERVER__PORT`)

## Testing Guidelines

- Use `axum-test` for HTTP integration tests
- Mock external dependencies or use test containers
- Test health endpoints in every test suite
- Run `docker-compose up -d` for integration tests with Redis/MinIO

## CI/CD Pipeline

The GitHub Actions CI pipeline runs:
1. `cargo fmt --all -- --check` (formatting)
2. `cargo clippy --all-targets --all-features -- -D warnings` (linting)
3. `cargo test --all-features` (tests with Redis/MinIO services)

All checks must pass before merging.

## Common Pitfalls

1. **Don't use `.unwrap()` or `.expect()`** - Use proper error handling
2. **Don't modify OpenTelemetry B3 propagation** - Required for Knative trace correlation
3. **Don't skip OpenAPI docs** - All endpoints must be documented
4. **Don't hardcode configuration** - Use `config.toml` or env vars
5. **Don't forget to update tests** - Test coverage is required

## Quick Reference

| Task | Command |
|------|---------|
| Run single test | `cargo test test_name` |
| Format code | `cargo fmt` |
| Lint code | `cargo clippy -- -D warnings` |
| Run locally | `docker-compose up -d && cargo run` |
| Build Docker | `docker build -t app .` |
| View docs | `cargo doc --no-deps --open` |
| Watch mode | `cargo watch -x run` |
