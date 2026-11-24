# Testing Guide

Complete testing strategy and best practices for {{ project_name }}.

## Table of Contents

- [Testing Philosophy](#testing-philosophy)
- [Unit Testing](#unit-testing)
- [Integration Testing](#integration-testing)
- [E2E Testing](#e2e-testing)
- [Performance Testing](#performance-testing)
- [Test Coverage](#test-coverage)
- [CI/CD Testing](#cicd-testing)
- [Testing Best Practices](#testing-best-practices)

---

## Testing Philosophy

### Testing Pyramid

```
        /\
       /  \
      / E2E \      Small number (5-10%)
     /--------\
    /Integration\   Medium number (20-30%)
   /------------\
  /   Unit Tests  \  Large number (60-75%)
 /________________\
```

- **Unit Tests**: Fast, isolated, test individual functions
- **Integration Tests**: Medium speed, test handler + dependencies
- **E2E Tests**: Slow, test complete workflows

### Test Categories

| Type | Speed | Dependencies | Coverage |
|------|--------|--------------|-----------|
| Unit | <1s | None | Business logic, pure functions |
| Integration | 1-10s | Docker services | Handlers, database{% if feature_s3 %}, storage{% endif %} |
| E2E | 30s-5m | Kind cluster | Full deployment |

---

## Unit Testing

### Writing Unit Tests

**Location**: In source files with `#[cfg(test)]` module

**Example** (`src/handlers/health.rs`):
```rust
#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::StatusCode;
    
    #[tokio::test]
    async fn test_liveness_handler() {
        let response = liveness().await;
        assert_eq!(response.status(), StatusCode::OK);
        
        let body = response.into_body();
        assert!(body.is_empty());
    }
    
    #[tokio::test]
    async fn test_readiness_handler() {
        let response = readiness().await;
        assert_eq!(response.status(), StatusCode::OK);
    }
}
```

### Test Organization

```
src/
├── handlers/
│   ├── api.rs
│   │   └── mod.rs
│   │       └── #[cfg(test)] tests { ... }
│   ├── health.rs
│   │   └── #[cfg(test)] tests { ... }
{% if feature_s3 %}
│   └── storage.rs
│       └── #[cfg(test)] tests { ... }
{% endif %}
```

### Running Unit Tests

```bash
# Run all unit tests
cargo test

# Run specific test
cargo test test_liveness_handler

# Run tests in module
cargo test handlers::health

# Run with output
cargo test -- --nocapture

# Run single-threaded
cargo test -- --test-threads=1
```

---

## Integration Testing

### Integration Test Structure

**Location**: `tests/` directory

**Example** (`tests/health_test.rs`):
```rust
use reqwest::Client;
use serde_json::Value;

#[tokio::test]
#[ignore]  // Ignored by default, run with --ignored
async fn test_health_endpoints() {
    let client = Client::new();
    let base_url = std::env::var("APP_URL")
        .unwrap_or_else(|_| "http://localhost:8080".to_string());
    
    // Test liveness
    let response = client.get(&format!("{}/health/live", base_url))
        .send()
        .await
        .expect("Failed to send request");
    
    assert_eq!(response.status(), 200);
    
    // Test readiness
    let response = client.get(&format!("{}/health/ready", base_url))
        .send()
        .await
        .expect("Failed to send request");
    
    assert_eq!(response.status(), 200);
    
    let body: Value = response.json().await.expect("Failed to parse JSON");
    assert_eq!(body["status"], "ready");
}
```

{% if feature_s3 %}

### S3 Integration Tests

**Example** (`tests/storage_test.rs`):
```rust
use reqwest::Client;
use serde_json::json;

#[tokio::test]
#[ignore]
async fn test_upload_download_cycle() {
    let client = Client::new();
    let base_url = "http://localhost:8080";
    
    // Upload file
    let upload_response = client
        .post(&format!("{}/api/upload", base_url))
        .json(&json!({
            "key": "test-file.txt",
            "data": base64::encode("Hello, World!")
        }))
        .send()
        .await
        .expect("Failed to upload");
    
    assert_eq!(upload_response.status(), 201);
    
    // Download file
    let download_response = client
        .get(&format!("{}/api/download/test-file.txt", base_url))
        .send()
        .await
        .expect("Failed to download");
    
    assert_eq!(download_response.status(), 200);
    let content = download_response.bytes().await.expect("Failed to get bytes");
    assert_eq!(content, b"Hello, World!");
    
    // Delete file
    let delete_response = client
        .delete(&format!("{}/api/delete/test-file.txt", base_url))
        .send()
        .await
        .expect("Failed to delete");
    
    assert_eq!(delete_response.status(), 204);
}

#[tokio::test]
#[ignore]
async fn test_list_objects() {
    let client = Client::new();
    let base_url = "http://localhost:8080";
    
    // List objects
    let response = client
        .get(&format!("{}/api/objects", base_url))
        .send()
        .await
        .expect("Failed to list");
    
    assert_eq!(response.status(), 200);
    
    let body: Value = response.json().await.expect("Failed to parse JSON");
    assert!(body["objects"].is_array());
}

{% endif %}
```

### Test Fixtures and Utilities

**Common test utilities** (`tests/common/mod.rs`):
```rust
use reqwest::Client;
use std::env;

pub struct TestClient {
    client: Client,
    base_url: String,
}

impl TestClient {
    pub fn new() -> Self {
        TestClient {
            client: Client::new(),
            base_url: env::var("APP_URL")
                .unwrap_or_else(|_| "http://localhost:8080".to_string()),
        }
    }
    
    pub async fn get(&self, path: &str) -> reqwest::Response {
        self.client
            .get(&format!("{}{}", self.base_url, path))
            .send()
            .await
            .expect("Failed to send GET request")
    }
    
    pub async fn post(&self, path: &str, body: serde_json::Value) -> reqwest::Response {
        self.client
            .post(&format!("{}{}", self.base_url, path))
            .json(&body)
            .send()
            .await
            .expect("Failed to send POST request")
    }
    
    pub async fn delete(&self, path: &str) -> reqwest::Response {
        self.client
            .delete(&format!("{}{}", self.base_url, path))
            .send()
            .await
            .expect("Failed to send DELETE request")
    }
}
```

**Usage in tests**:
```rust
use common::TestClient;

#[tokio::test]
#[ignore]
async fn test_with_fixture() {
    let client = TestClient::new();
    
    let response = client.get("/health/live").await;
    assert_eq!(response.status(), 200);
}
```

### Running Integration Tests

```bash
# Start the local Kind environment (Redis, RustFS, PostgreSQL, Kafka as enabled)
make local-up

# Run the ignored, infrastructure-backed suites
cargo test --all-features -- --ignored --test-threads=1

# Run one suite only
cargo test --all-features --test integration -- --ignored

# Run directly against a deployed service
make dev-test
```

---

## E2E Testing

End-to-end testing is owned by CI; there is no local E2E suite to keep in sync
with the template anymore.

| Layer | Where | What it proves |
|-------|-------|----------------|
| Template generation matrix (template repo CI) | `.github/workflows/template-generate-and-validate.yaml` (`generate-and-validate` job) | 12 feature combinations generate, format, lint, and compile |
| Full-stack validation | same workflow, `full-stack` job | All-features project builds (debug + release), Docker image builds, Helm chart and overlays render, Flux config renders |
| Live E2E (template repo CI) | `.github/workflows/template-e2e-test.yaml` | Kind + Flux deploy of the generated project, health/event/storage assertions per scenario, plus a 305s SSE stream for Deployment mode |
| Local smoke | `make local-up` then `make dev-test` | The service runs in a real Kind cluster with the same manifests |

To reproduce a live cluster locally, use the same path the E2E job uses:

```bash
make local-up        # Kind{% if workload_type == "Knative" %} + Knative{% endif %} + Flux + app
make dev-status      # confirm the {% if workload_type == "Deployment" %}Deployment{% else %}Knative service{% endif %} is Ready
make dev-test        # run the integration suite against the cluster
make local-down      # tear it down
```

The CI-run scenarios are listed in the workflow matrix; add a row there rather
than a bespoke script.

---

## Performance Testing

### Load Testing with hey

```bash
# Install hey
go install github.com/rakyll/hey@latest

# Load test health endpoint
hey -n 1000 -c 10 http://localhost:8080/health/live

# Load test with concurrency
hey -n 5000 -c 50 http://localhost:8080/metrics
```

### Benchmarking with Criterion

**Add to Cargo.toml**:
```toml
[dev-dependencies]
criterion = "0.5"

[[bench]]
name = "my_benchmark"
harness = false
```

**Create benchmark** (`benches/my_benchmark.rs`):
```rust
use criterion::{black_box, criterion_group, criterion_main, Criterion};
use {{ crate_name }}::handlers;

fn benchmark_liveness(c: &mut Criterion) {
    c.bench_function("liveness", |b| {
        b.iter(|| handlers::health::liveness())
    });
}

criterion_group!(benches, benchmark_liveness);
criterion_main!(benches);
```

**Run benchmark**:
```bash
cargo bench
```

### Flamegraph Profiling

```bash
# Install flamegraph
cargo install flamegraph

# Profile application
cargo flamegraph

# View flamegraph
open flamegraph.svg
```

---

## Test Coverage

### Tarpaulin

**Install**:
```bash
cargo install cargo-tarpaulin
```

**Generate Coverage**:
```bash
# Generate HTML report
cargo tarpaulin --out Html

# Generate LCOV report
cargo tarpaulin --out Lcov

# View HTML report
open tarpaulin-report.html
```

**Coverage Goals**:
- Unit tests: > 90% coverage
- Integration tests: > 70% coverage
- Overall: > 80% coverage

### CI Integration

**GitHub Actions**:
```yaml
name: Coverage

on: [push, pull_request]

jobs:
  coverage:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
    
    - name: Install tarpaulin
      run: cargo install cargo-tarpaulin
    
    - name: Generate coverage
      run: cargo tarpaulin --out Lcov
    
    - name: Upload to Codecov
      uses: codecov/codecov-action@v3
      with:
        files: ./lcov.info
```

---

## CI/CD Testing

### GitHub Actions Workflow

**`.github/workflows/test.yaml`**:
```yaml
name: Test

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    
    services:
      redis:
        image: redis:7
        ports:
          - 6379:6379
    
    steps:
    - uses: actions/checkout@v4
    
    - name: Install Rust toolchain
      uses: actions-rust-lang/setup-rust-toolchain@v1
      with:
        toolchain: stable
    
    - name: Cache cargo
      uses: actions/cache@v3
      with:
        path: ~/.cargo/registry
        key: {% raw %}${{ runner.os }}-cargo-registry-${{ hashFiles('**/Cargo.lock') }}{% endraw %}
    
    - name: Cache cargo index
      uses: actions/cache@v3
      with:
        path: ~/.cargo/git
        key: {% raw %}${{ runner.os }}-cargo-index-${{ hashFiles('**/Cargo.lock') }}{% endraw %}
    
    - name: Cache cargo build
      uses: actions/cache@v3
      with:
        path: target
        key: {% raw %}${{ runner.os }}-cargo-build-target-${{ hashFiles('**/Cargo.lock') }}{% endraw %}
    
    {% if feature_s3 %}
    - name: Start RustFS
      run: |
        docker run -d --name rustfs -p 9000:9000 -p 9001:9001 \
          -e RUSTFS_ACCESS_KEY=rustfsadmin \
          -e RUSTFS_SECRET_KEY=rustfsadmin \
          rustfs/rustfs:1.0.1 /data
        for i in $(seq 1 30); do
          curl -fsS http://localhost:9000/health/live >/dev/null 2>&1 && break
          sleep 1
        done
        curl -fsS http://localhost:9000/health/live >/dev/null

    - name: Initialize RustFS bucket
      run: |
        cargo install rustfs-cli
        rc alias set local http://localhost:9000 rustfsadmin rustfsadmin
        rc bucket create -p local/data
    {% endif %}

    - name: Run unit tests
      run: cargo test --verbose
    
    - name: Run integration tests
      run: cargo test --test '*' --ignored --nocapture
      env:
        APP__REDIS__URL: redis://localhost:6379
        {% if feature_s3 %}
        APP__S3__ENDPOINT: http://localhost:9000
        APP__S3__BUCKET: data
        AWS_ACCESS_KEY_ID: rustfsadmin
        AWS_SECRET_ACCESS_KEY: rustfsadmin
        {% endif %}
    
    - name: Run linting
      run: cargo clippy --all-targets -- -D warnings
    
    - name: Check formatting
      run: cargo fmt --all --check
    
    - name: Security audit
      run: cargo audit
    
    - name: Generate coverage
      run: |
        cargo install cargo-tarpaulin
        cargo tarpaulin --out Lcov
```

---

## Testing Best Practices

### Arrange-Act-Assert (AAA)

**Good**:
```rust
#[test]
fn test_upload() {
    // Arrange
    let client = TestClient::new();
    let data = base64::encode("test data");
    
    // Act
    let response = client.post("/api/upload", json!({"key": "test.txt", "data": &data})).await;
    
    // Assert
    assert_eq!(response.status(), 201);
}
```

### Test Isolation

Each test should be independent:

```rust
#[tokio::test]
#[ignore]
async fn test_upload_isolated() {
    // Create unique key per test
    let key = format!("test-{}", uuid::Uuid::new_v4());
    
    // Test upload
    // ...
    
    // Cleanup
    client.delete(&format!("/api/delete/{}", key)).await;
}
```

### Meaningful Names

```rust
// Good
#[test]
async fn test_upload_returns_201_on_success() {}

#[test]
async fn test_upload_returns_400_on_missing_key() {}

// Bad
#[test]
async fn test_upload() {}
```

### Avoid Flaky Tests

Use waiting/polling instead of fixed sleeps:

```rust
// Bad
sleep(1);  // Flaky on slow machines

// Good
tokio::time::timeout(Duration::from_secs(5), async {
    // Wait for condition
    assert!(ready());
}).await?;
```

### Mock External Dependencies

Use mocking for external APIs:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use mockall::mock;
    
    mock! {
        Storage {}
        impl StorageTrait for Storage {
            async fn read(&self, key: &str) -> Result<Vec<u8>, Error>;
        }
    }
    
    #[tokio::test]
    async fn test_with_mock_storage() {
        let mut mock = MockStorage::new();
        mock.expect_read()
            .returning(|_| Ok(b"data".to_vec()));
        
        // Test with mock
    }
}
```

---

## Next Steps

- **Development**: See `docs/DEVELOPMENT.md`
- **API Docs**: See `docs/API.md`
- **Monitoring**: See `docs/MONITORING.md`
- **Troubleshooting**: See `docs/TROUBLESHOOTING.md`
