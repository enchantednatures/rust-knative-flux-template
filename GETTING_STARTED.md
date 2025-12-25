# Getting Started with the Rust Knative FluxCD Template

This is a production-ready microservice template with optional S3/MinIO storage support, powered by cargo-generate.

## Prerequisites

- **Rust 1.75+**: Install from https://rustup.rs/
- **cargo-generate**: `cargo install cargo-generate`
- **Docker**: For building container images
- **Kind**: For local Kubernetes cluster - Install from https://kind.sigs.k8s.io/docs/user/quick-start/
- **kubectl 1.24+**: For Kubernetes operations
- **Knative Serving 1.20+**: Automatically installed with `make dev-up`
- **FluxCD 2.0+**: For GitOps deployment

## Creating a New Project

### Step 1: Generate from Template

```bash
cargo generate --git https://github.com/your-org/rust-knative-flux-template

# Follow prompts:
# ? Project name: my-awesome-service
# ? Include S3-compatible storage (MinIO/S3)? (y/n)
```

This creates a new directory with your project name.

### Step 2: Enter Project Directory

```bash
cd my-awesome-service
```

## Local Development (Without S3)

If you selected "No" for S3 storage:

### Start Development Environment

```bash
make dev-up
```

This sets up:
- Kind cluster with local Docker registry
- Knative Serving v1.20.0
- Redis for caching
- OpenTelemetry Collector, Jaeger, and Prometheus for observability
- Your application deployed to Knative

Services are accessible at:
- Application: http://localhost:8080
- Jaeger UI: http://localhost:16686
- Prometheus: http://localhost:9090
- Redis: localhost:6379

### Run Application Tests

```bash
cargo test
```

### Rebuild After Changes

```bash
make dev-restart
```

### View Logs

```bash
make dev-logs
```

### Stop Environment

```bash
make dev-down
```

## Local Development (With S3)

If you selected "Yes" for S3 storage:

### Start Development Environment

```bash
make dev-up
```

This sets up everything from the non-S3 version, plus:
- MinIO S3-compatible storage (automatically initialized with `data` bucket)

Additional services:
- MinIO S3 API: http://localhost:9000
- MinIO Console: http://localhost:9001
  - Username: `minioadmin`
  - Password: `minioadmin`

### Use Storage in Code

```rust
async fn handler(State(state): State<AppState>) -> impl IntoResponse {
    // Write
    state.storage.write("file.txt", b"content".to_vec()).await.ok();
    
    // Read
    let data = state.storage.read("file.txt").await.ok();
    
    "OK"
}
```

### Run Tests (Including S3 Integration)

```bash
# Run all tests
cargo test

# Run only S3 integration tests
cargo test --test storage_test -- --ignored --nocapture
```

## Configuration

### Environment Variables

Override config via environment variables (highest priority):

```bash
# Server
export APP__SERVER__HOST="0.0.0.0"
export APP__SERVER__PORT="8080"

# Redis
export APP__REDIS__URL="redis://redis.services.svc.cluster.local:6379"

# Telemetry
export APP__TELEMETRY__LOG_LEVEL="debug"
export APP__TELEMETRY__OTLP_ENDPOINT="http://otel-collector.observability.svc.cluster.local:4317"

# S3 (if enabled, pre-configured in dev environment)
export APP__S3__ENDPOINT="http://minio.services.svc.cluster.local:9000"
export APP__S3__BUCKET="data"
export APP__S3__REGION="us-east-1"
export AWS_ACCESS_KEY_ID="minioadmin"
export AWS_SECRET_ACCESS_KEY="minioadmin"
```

### Config Files

Priority (highest first):
1. Environment variables
2. `config/{APP_ENV}.toml` (default: development)
3. `config/default.toml`

Edit `config/development.toml` for dev-specific settings.

## Project Structure

```
my-awesome-service/
├── src/
│   ├── main.rs           # Entry point, initialization
│   ├── lib.rs            # Library exports
│   ├── config.rs         # Configuration loader
│   ├── state.rs          # AppState (Redis, Storage)
│   ├── routes.rs         # Router setup
│   ├── handlers/         # HTTP handlers
│   │   ├── api.rs
│   │   ├── health.rs
│   │   └── mod.rs
│   ├── error.rs          # Error types
│   └── observability.rs  # Tracing & metrics
├── config/
│   ├── default.toml      # Default settings
│   └── development.toml  # Dev overrides
├── deploy/
│   ├── base/             # Base Kubernetes manifests
│   │   ├── knative-service.yaml
│   │   ├── secret.yaml.example
│   │   └── kustomization.yaml
│   ├── overlays/         # Environment patches
│   │   ├── dev/
│   │   ├── staging/
│   │   └── prod/
│   └── flux/             # FluxCD automation
├── tests/                # Integration tests
├── docker-compose.yaml   # Local development services
├── Dockerfile            # Container image
├── Cargo.toml           # Dependencies
├── STORAGE.md           # S3/MinIO guide (if S3 enabled)
└── README.md            # Full documentation
```

## Deployment

### Build & Test Locally

```bash
# Lint
cargo fmt --all --check
cargo clippy --all-targets -- -D warnings

# Test
cargo test

# Build
cargo build --release
```

### Docker Image

Build and run locally:

```bash
docker build -t my-service:latest .
docker run --rm -it \
  --network host \
  -e APP__REDIS__URL=redis://localhost:6379 \
  my-service:latest
```

### Kubernetes (Knative + FluxCD)

1. **Create namespace & secrets**:
   ```bash
   kubectl create namespace my-service
   
   kubectl create secret generic rust-service-secrets \
     --from-literal=redis-url='redis://redis:6379' \
     -n my-service
   ```

2. **Apply manifests**:
   ```bash
   # Option A: Manual apply
   kubectl apply -k deploy/overlays/dev -n my-service
   
   # Option B: Via FluxCD (recommended)
   flux create source git my-service \
     --url=https://github.com/your-org/my-service \
     --branch=main
   
   flux create kustomization my-service \
     --source=GitRepository/my-service \
     --path=deploy/overlays/prod \
     --prune=true
   ```

3. **View service**:
   ```bash
   kubectl get ksvc -n my-service
   
   # Get URL
   kubectl get ksvc my-service -n my-service -o jsonpath='{.status.url}'
   ```

## Health Checks

Two endpoints for Kubernetes probes:

- **Liveness**: `GET /health/live` - Is the service alive?
- **Readiness**: `GET /health/ready` - Can it handle traffic? (checks Redis)

These are configured in `deploy/base/knative-service.yaml`.

## Observability

### Traces (Jaeger)

All requests are traced with:
- B3 propagation (Knative-compatible)
- Resource attributes (service, pod, namespace)
- Custom spans per handler

View traces: http://localhost:16686

### Metrics (Prometheus)

Metrics exposed at `GET /metrics`:
- HTTP request latency (histograms)
- Active connections
- Request count per endpoint

View metrics: http://localhost:9090

### Logs

Structured JSON logs with:
- Trace IDs (for correlation)
- Severity levels
- Contextual fields

Example:
```json
{
  "timestamp": "2024-01-10T12:34:56.789Z",
  "level": "INFO",
  "target": "my_service::handlers::api",
  "message": "Request received",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "http.method": "GET",
  "http.path": "/api/data"
}
```

## Git Workflow

1. **Create feature branch**:
   ```bash
   git checkout -b feature/my-feature
   ```

2. **Make changes** and test:
   ```bash
   cargo fmt --all
   cargo clippy --all-targets -- -D warnings
   cargo test
   ```

3. **Commit with message**:
   ```bash
   git commit -m "feat: add my feature"
   ```

4. **Push and create PR**:
   ```bash
   git push origin feature/my-feature
   ```

5. **CI/CD pipeline runs**:
   - Linting (rustfmt, clippy)
   - Tests (unit + integration)
   - Docker build & push
   - Security scan (Trivy)

## Common Tasks

### Add a New Handler

1. Create file in `src/handlers/`:
   ```rust
   // src/handlers/my_handler.rs
   use axum::{extract::State, http::StatusCode, response::IntoResponse};
   use crate::state::AppState;
   
   pub async fn my_endpoint(State(state): State<AppState>) -> impl IntoResponse {
       // Your logic here
       StatusCode::OK
   }
   ```

2. Add to `src/handlers/mod.rs`:
   ```rust
   mod my_handler;
   pub use my_handler::my_endpoint;
   ```

3. Add route in `src/routes.rs`:
   ```rust
   .route("/api/my-endpoint", get(handlers::my_endpoint))
   ```

### Add S3 Operations

If you have S3 enabled:

```rust
pub async fn upload_file(
    State(state): State<AppState>,
    body: Bytes,
) -> Result<impl IntoResponse, String> {
    state
        .storage
        .write("uploads/file.bin", body.to_vec())
        .await
        .map_err(|e| e.to_string())?;
    
    Ok(StatusCode::CREATED)
}
```

### Scale Configuration

Edit `deploy/overlays/{env}/kustomization.yaml`:

```yaml
patches:
  - target:
      kind: Service
      name: rust-service
    patch: |-
      - op: add
        path: /spec/template/metadata/annotations/autoscaling.knative.dev~1min-scale
        value: "1"
      - op: add
        path: /spec/template/metadata/annotations/autoscaling.knative.dev~1max-scale
        value: "10"
```

### Update Dependencies

```bash
cargo update
cargo upgrade  # (requires `cargo-edit`)
```

Run tests after updating:

```bash
cargo test
```

## Troubleshooting

### Kind cluster fails to start

```bash
# Check if Docker is running
docker ps

# Check for port conflicts
lsof -i :8080 :6379 :9000

# Clean up and retry
make dev-down
make dev-up
```

### Application not accessible

```bash
# Check if port forwarding is running
make dev-forward

# Verify application is deployed
make dev-status

# View application logs
make dev-logs
```

### Services not ready

```bash
# Check specific service status
kubectl get pods -n services
kubectl get pods -n observability
kubectl get ksvc -n default

# View logs for a specific service
kubectl logs -l app=redis -n services
kubectl logs -l app=jaeger -n observability
```

## Next Steps

1. **Update package metadata** in `Cargo.toml`:
   - `authors`
   - `description`
   - `repository`

2. **Read** `README.md` for detailed documentation

3. **Explore handlers** in `src/handlers/` for examples

4. **Check CI** in `.github/workflows/ci.yaml`

5. **For S3**: Read `STORAGE.md` (if enabled)

6. **Deploy** to Kubernetes following the deployment section

## Support

- **Documentation**: See `README.md` and `STORAGE.md`
- **Issues**: Create GitHub issues in your repo
- **Questions**: Check handler examples in `src/handlers/`

## License

MIT (see LICENSE file)

Good luck building! 🚀
