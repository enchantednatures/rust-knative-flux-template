# Development Guide

Guide for local development, adding features, and following best practices for example-app.

## Table of Contents

- [Setting Up Local Environment](#setting-up-local-environment)
- [Project Structure](#project-structure)
- [Development Workflow](#development-workflow)
- [Adding New Features](#adding-new-features)
- [Running Tests](#running-tests)
- [Code Quality Tools](#code-quality-tools)
- [Debugging](#debugging)
- [Git Workflow](#git-workflow)

---

## Setting Up Local Environment

### Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Rust | 1.92+ | https://rustup.rs/ |
| Cargo | 1.92+ | Installed with Rust |
| Docker | 20.10+ | https://docs.docker.com/get-docker/ |
| Docker Compose | 2.0+ | Included with Docker |
| cargo-watch | Latest | `cargo install cargo-watch` |
| cargo-edit | Latest | `cargo install cargo-edit` |

### Installation Steps

```bash
# Install Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source $HOME/.cargo/env

# Install useful tools
cargo install cargo-watch
cargo install cargo-edit
cargo install cargo-audit
cargo install cargo-outdated

# Verify installation
rustc --version
cargo --version
```

### Starting Local Services

```bash
# Start all services (Redis, MinIO, Jaeger, Prometheus, OTEL Collector)
docker-compose up -d

# Verify services are running
docker-compose ps

# View logs
docker-compose logs -f

# Stop services
docker-compose down

# Stop and clean volumes
docker-compose down -v
```

**Services Started**:
- Redis (port 6379) - Caching/sessions
- MinIO S3 API (port 9000) - Object storage
- MinIO Console (port 9001) - Web UI at http://localhost:9001
- OpenTelemetry Collector (port 4317) - Telemetry collection
- Jaeger (port 16686) - Distributed tracing UI
- Prometheus (port 9090) - Metrics UI

### Running the Application

```bash
# Run application
cargo run

# Run with specific port
APP__SERVER__PORT=9000 cargo run

# Run with debug logging
RUST_LOG=debug cargo run

# Run with auto-reload (recommended for development)
cargo watch -q -c -w src -x run

# Build optimized release binary
cargo build --release
./target/release/example-app
```

### Verify Application is Running

```bash
# Health check
curl http://localhost:8080/health/live

# Readiness check
curl http://localhost:8080/health/ready

# Metrics
curl http://localhost:8080/metrics | head


# Test S3 upload
curl -X POST http://localhost:8080/api/upload \
  -H "Content-Type: application/json" \
  -d '{"key":"test.txt","data":"aGVsbG8="}'

# List objects
curl http://localhost:8080/api/objects

```

---

## Project Structure

```
example-app/
├── src/
│   ├── main.rs                    # Application entry point
│   ├── lib.rs                     # Module exports
│   ├── config.rs                  # Configuration loading
│   ├── state.rs                   # AppState (Redis, S3)
│   ├── error.rs                   # Error types
│   ├── observability.rs            # OpenTelemetry setup
│   ├── routes.rs                  # Router definition
│   └── handlers/
│       ├── mod.rs                 # Handler exports
│       ├── api.rs                 # API handlers
│       ├── storage.rs             # S3 operation handlers
│       └── health.rs             # Health check handlers
├── config/
│   ├── default.toml               # Default configuration
│   └── development.toml           # Development overrides
├── deploy/
│   ├── base/                     # Base Kubernetes manifests
│   ├── overlays/                 # Environment-specific patches
│   └── flux/                     # FluxCD GitOps config
├── docker/
│   ├── otel-collector-config.yaml # OpenTelemetry config
│   └── prometheus.yaml            # Prometheus config
├── tests/
│   ├── health_test.rs             # Health endpoint tests
│   ├── storage_test.rs            # S3 integration tests
│   └── common/
│       └── mod.rs                # Test utilities
├── docs/                         # Documentation
├── docker-compose.yaml           # Local development services
├── Dockerfile                    # Container build
├── Cargo.toml                   # Rust dependencies
└── README.md                    # This file
```

---

## Development Workflow

### Typical Development Cycle

```bash
# 1. Create feature branch
git checkout -b feature/my-feature

# 2. Start local services
docker-compose up -d

# 3. Run with auto-reload
cargo watch -q -c -w src -x run

# 4. Make changes
# Edit files in src/

# 5. Run tests in another terminal
cargo test

# 6. Check code quality
cargo fmt
cargo clippy -- -D warnings

# 7. Commit
git add .
git commit -m "feat: add my feature"

# 8. Push and create PR
git push origin feature/my-feature
```

### Using docker-compose for Integration Testing

```bash
# Start services
docker-compose up -d

# Wait for services to be ready
docker-compose ps

# Run tests with services
cargo test -- --ignored --nocapture

# Clean up
docker-compose down -v
```

---

## Adding New Features

### Adding a New API Endpoint

#### Step 1: Create Handler

Create new file in `src/handlers/`:

```rust
// src/handlers/my_feature.rs
use axum::{extract::State, Json, response::IntoResponse};
use serde_json::json;
use crate::state::AppState;

pub async fn my_handler(
    State(state): State<AppState>,
) -> impl IntoResponse {
    Json(json!({
        "message": "Hello from my feature!",
        "redis_connected": true,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_my_handler() {
        let response = my_handler(State(AppState::new_for_test())).await;
        assert_eq!(response.status(), 200);
    }
}
```

#### Step 2: Export Handler

Add to `src/handlers/mod.rs`:

```rust
pub mod api;
pub mod health;
pub mod storage;

pub mod my_feature;

pub use my_feature::my_handler;
```

#### Step 3: Add Route

Add to `src/routes.rs`:

```rust
use axum::{Router, routing::get};
use crate::handlers;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/health/live", get(handlers::health::liveness))
        .route("/health/ready", get(handlers::health::readiness))
        .route("/metrics", get(handlers::metrics))
        // New route
        .route("/api/my-feature", get(handlers::my_handler))
}
```

#### Step 4: Test

```bash
# Run tests
cargo test

# Run application
cargo run

# Test endpoint
curl http://localhost:8080/api/my-feature
```



### Adding a New S3 Operation

#### Step 1: Add Handler in `src/handlers/storage.rs`

```rust
pub async fn copy_object(
    State(state): State<AppState>,
    Path((src, dst)): Path<(String, String)>,
) -> Result<StatusCode, AppError> {
    state
        .storage
        .copy(&src, &dst)
        .await
        .map_err(|e| AppError::InternalServerError(format!("Copy failed: {}", e)))?;
    
    Ok(StatusCode::OK)
}
```

#### Step 2: Add Route

```rust
.route("/api/copy/:src/:dst", post(handlers::storage::copy_object))
```

#### Step 3: Write Test

```rust
#[tokio::test]
#[ignore]
async fn test_copy_object() {
    // Setup: Start docker-compose
    // Test copy operation
    // Verify source and destination exist
}
```



### Adding Custom Metrics

```rust
use opentelemetry::metrics::{Counter, Histogram};
use opentelemetry::{global, KeyValue};

pub struct Metrics {
    pub request_count: Counter<u64>,
    pub request_duration: Histogram<f64>,
}

impl Metrics {
    pub fn new() -> Self {
        let meter = global::meter("example_app_with_s3");
        
        Metrics {
            request_count: meter
                .u64_counter("http_requests_total")
                .with_description("Total HTTP requests")
                .init(),
            request_duration: meter
                .f64_histogram("http_request_duration_seconds")
                .with_description("HTTP request duration")
                .init(),
        }
    }
}

// Use in handler
pub async fn my_handler() -> impl IntoResponse {
    let metrics = Metrics::new();
    let start = std::time::Instant::now();
    
    // Your handler logic here
    
    let duration = start.elapsed().as_secs_f64();
    metrics.request_duration.record(duration, &[]);
    metrics.request_count.add(1, &[]);
    
    StatusCode::OK
}
```

### Adding Custom Tracing Spans

```rust
use tracing::{instrument, info, error};

#[instrument(skip(state), fields(operation = "my_operation"))]
pub async fn my_handler(
    State(state): State<AppState>,
) -> Result<Json<Value>, AppError> {
    info!("Starting my operation");
    
    // Custom span
    let result = my_expensive_function().await;
    
    match result {
        Ok(data) => {
            info!("Operation completed successfully");
            Ok(Json(json!({"data": data})))
        }
        Err(e) => {
            error!("Operation failed: {}", e);
            Err(AppError::InternalServerError(e.to_string()))
        }
    }
}

#[instrument]
async fn my_expensive_function() -> Result<String, Box<dyn std::error::Error>> {
    tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
    Ok("result".to_string())
}
```

---

## Running Tests

### Unit Tests

```bash
# Run all unit tests
cargo test

# Run with output
cargo test -- --nocapture

# Run specific test
cargo test test_my_handler

# Run tests in specific module
cargo test handlers::health

# Run with filter
cargo test -- my_feature
```

### Integration Tests

```bash
# Run all tests (unit + integration)
cargo test

# Run only ignored tests (integration tests)
cargo test -- --ignored

# Run integration tests with output
cargo test --test '*' -- --ignored --nocapture

# Run single-threaded (useful for integration tests)
cargo test -- --test-threads=1
```

### Test Coverage

```bash
# Install tarpaulin
cargo install cargo-tarpaulin

# Generate coverage report
cargo tarpaulin --out Html

# View coverage report
open tarpaulin-report.html
```

---

## Code Quality Tools

### Formatting

```bash
# Format code
cargo fmt

# Check if code is formatted
cargo fmt --check

# Format all files (including dependencies)
cargo fmt --all
```

### Linting

```bash
# Run Clippy (Rust linter)
cargo clippy

# Run Clippy with warnings as errors
cargo clippy -- -D warnings

# Run Clippy on all targets
cargo clippy --all-targets

# Fix automatically fixable issues
cargo clippy --fix
```

### Security Auditing

```bash
# Audit dependencies for security vulnerabilities
cargo audit

# Audit and display info
cargo audit -v

# Update database
cargo audit --fetch

# Allow specific advisory (use with caution)
cargo audit --advisory-id RUSTSEC-2020-0001 --allow
```

### Documentation

```bash
# Generate documentation
cargo doc

# Generate with private items
cargo doc --document-private-items

# Generate and open in browser
cargo doc --no-deps --open

# Check documentation coverage
cargo doc --no-deps
```

### Dependency Management

```bash
# Update dependencies
cargo update

# Upgrade dependencies (to latest compatible)
cargo upgrade

# Upgrade dependencies (to latest major version)
cargo upgrade --latest

# Check for outdated dependencies
cargo outdated

# Check dependency graph
cargo tree
```

---

## Debugging

### Logging

```bash
# Enable debug logging
RUST_LOG=debug cargo run

# Enable trace logging (very verbose)
RUST_LOG=trace cargo run

# Log specific module
RUST_LOG=example_app_with_s3=debug cargo run

# Log multiple modules
RUST_LOG=example_app_with_s3=debug,redis=trace cargo run

# Log with JSON format
APP__TELEMETRY__LOG_FORMAT=json RUST_LOG=debug cargo run
```

### Using lldb/rust-gdb

```bash
# Install lldb (macOS)
brew install lldb

# Install rust-gdb (Linux)
rustup component add rust-gdb

# Run with debugger
rust-lldb target/debug/example-app

# In lldb
(gdb) b src/main.rs:42  # Set breakpoint
(gdb) run               # Run application
(gdb) n                 # Next line
(gdb) p variable_name   # Print variable
(gdb) c                 # Continue
```

### Profiling

```bash
# Install flamegraph
cargo install flamegraph

# Profile application
cargo flamegraph

# View flamegraph
open flamegraph.svg

# Profile with specific arguments
cargo flamegraph -- --release
```

### Memory Profiling

```bash
# Use `jemalloc` for memory tracking

# Add to Cargo.toml
[dependencies]
jemalloc = { version = "0.5", optional = true }

[features]
jemalloc = ["jemalloc"]

# Run with jemalloc
RUSTFLAGS="--cfg jemalloc" cargo run --features jemalloc --release
```

---

## Git Workflow

### Commit Message Format

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <subject>

<body>

<footer>
```

Types:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code style changes (formatting, etc.)
- `refactor`: Code refactoring
- `test`: Adding or updating tests
- `chore`: Build process, tooling, dependencies

Examples:
```
feat(api): add user endpoint

Add GET /api/user/:id endpoint to retrieve user information.

Closes #123
```

```
fix(storage): resolve S3 timeout issue

Increased timeout from 30s to 60s for large file uploads.

Fixes #456
```

### Branch Naming

```
feature/add-s3-support
fix/redis-connection-timeout
docs/update-api-reference
refactor/improve-error-handling
test/add-integration-tests
```

### Pre-commit Hooks

Create `.git/hooks/pre-commit`:

```bash
#!/bin/bash

# Run formatting
cargo fmt --all --check

# Run linting
cargo clippy --all-targets -- -D warnings

# Run tests
cargo test

# If any command fails, abort commit
if [ $? -ne 0 ]; then
    echo "Pre-commit checks failed. Aborting commit."
    exit 1
fi
```

Make it executable:
```bash
chmod +x .git/hooks/pre-commit
```

### Using Git Worktrees

Work on multiple branches simultaneously:

```bash
# Create worktree
git worktree add ../example-app-feature feature/my-feature

# Navigate to worktree
cd ../example-app-feature

# Make changes, commit

# Cleanup when done
cd ..
git worktree remove ../example-app-feature
```

---

## IDE Configuration

### VS Code

Create `.vscode/settings.json`:

```json
{
  "rust-analyzer.checkOnSave.command": "clippy",
  "rust-analyzer.checkOnSave.extraArgs": [
    "-D",
    "warnings"
  ],
  "rust-analyzer.cargo.loadOutDirsFromCheck": true,
  "rust-analyzer.cargo.features": "all",
  "rust-analyzer.rustfmt.extraArgs": ["+nightly"],
  "[rust]": {
    "editor.formatOnSave": true,
    "editor.defaultFormatter": "rust-lang.rust-analyzer"
  }
}
```

Recommended extensions:
- `rust-lang.rust-analyzer`
- `vadimcn.vscode-lldb`
- `tamasfe.even-better-toml`
- `eamodio.gitlens`

### IntelliJ IDEA / CLion

Install the **Rust plugin**:
- Settings → Plugins → Browse Repositories → Search "Rust"
- Install and restart IDE

---

## Performance Tips

### Optimize Development Builds

Add to `.cargo/config.toml`:

```toml
[build]
# Use incremental compilation
incremental = true

# Linker optimizations for faster builds
[target.x86_64-unknown-linux-gnu]
rustflags = ["-C", "link-arg=-fuse-ld=lld"]

[target.x86_64-apple-darwin]
rustflags = ["-C", "link-arg=-fuse-ld=ld64.lld"]
```

### Reduce Compile Times

```bash
# Use fewer threads to reduce memory usage
CARGO_BUILD_JOBS=2 cargo build

# Skip doc builds
cargo build --no-doc
```

---

## Next Steps

- **API Documentation**: See `docs/API.md`
- **Configuration**: See `docs/CONFIGURATION.md`
- **Testing**: See `docs/TESTING.md`
- **Deployment**: See `docs/DEPLOYMENT.md`
- **Troubleshooting**: See `docs/TROUBLESHOOTING.md`
