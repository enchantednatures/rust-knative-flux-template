# example-app

A production-ready Rust microservice template for Knative Serverless and FluxCD GitOps, with optional S3-compatible storage support (MinIO/AWS S3).


## Features

- 🚀 **Knative Serverless**: Auto-scaling HTTP service with CloudEvents support
- 📦 **S3-Compatible Storage**: Integrated OpenDAL for MinIO/AWS S3 object storage
- 🔍 **Observability**: OpenTelemetry instrumentation with Jaeger and Prometheus
- 🔄 **GitOps Ready**: FluxCD manifests for automated deployments
- 🏗️ **Infrastructure as Code**: Terraform modules for bucket management
- 🧪 **Fully Tested**: Integration tests with MinIO and Redis
- 📝 **Type-Safe**: Rust with strict compiler checks
- ⚡ **Fast**: Built on Tokio async runtime

## Quick Start

### Local Development

1. **Prerequisites**
   - Docker & Docker Compose
   - Rust 1.92+
   - cargo-generate (optional, for new projects)

2. **Start Local Services**
   ```bash
   docker-compose up -d
   ```

   This starts:
   - Redis (port 6379)
   - MinIO with S3-compatible API (port 9000)
   - MinIO Web Console (port 9001)
   - Jaeger tracing (port 16686)
   - Prometheus metrics (port 9090)
   - OpenTelemetry Collector

3. **Run the Service**
   ```bash
   # Configure environment (optional, defaults work)
   export APP__SERVER__PORT=8080
   export APP__REDIS__URL=redis://localhost:6379
   
   # Run with auto-reload
   cargo watch -q -c -w src -x run
   ```

4. **Test S3 Integration**
   ```bash
   # Write object
   curl -X POST http://localhost:8080/api/upload \
     -H "Content-Type: application/json" \
     -d '{"key": "test.txt", "data": "Hello MinIO"}'
   
   # List objects
   curl http://localhost:8080/api/objects
   
   # Download object
   curl http://localhost:8080/api/download/test.txt
   ```

5. **View Traces & Metrics**
   - Jaeger: http://localhost:16686
   - Prometheus: http://localhost:9090
   - MinIO Console: http://localhost:9001 (minioadmin/minioadmin)

### Kubernetes Deployment

1. **Prerequisites**
   - Kubernetes 1.24+
   - Knative 1.5+
   - FluxCD

2. **Deploy with FluxCD**
   ```bash
   kubectl apply -f deploy/flux/git-repository.yaml
   kubectl apply -f deploy/flux/kustomization.yaml
   ```

3. **Deploy Directly**
   ```bash
   # Development environment
   kubectl apply -k deploy/overlays/dev
   
   # Staging environment
   kubectl apply -k deploy/overlays/staging
   
   # Production environment
   kubectl apply -k deploy/overlays/prod
   ```

4. **Configure S3 Credentials**
   ```bash
   kubectl create secret generic example-app-s3 \
     --from-literal=s3-endpoint=s3.amazonaws.com \
     --from-literal=s3-bucket=my-bucket \
     --from-literal=s3-region=us-east-1 \
     --from-literal=aws-access-key-id=$AWS_ACCESS_KEY_ID \
     --from-literal=aws-secret-access-key=$AWS_SECRET_ACCESS_KEY
   ```

## Project Structure

```
example-app/
├── src/
│   ├── main.rs           # Application entry point with S3 setup
│   ├── lib.rs            # Module exports
│   ├── config.rs         # Configuration with S3Config
│   ├── state.rs          # AppState with optional storage Operator
│   ├── error.rs          # Error handling
│   ├── observability.rs  # OpenTelemetry setup
│   ├── routes.rs         # Route definitions
│   ├── handlers/
│   │   ├── api.rs        # API handlers with S3 operations
│   │   ├── health.rs     # Health check endpoints
│   │   └── mod.rs        # Handler exports
│
├── config/
│   ├── default.toml      # Default configuration with S3 settings
│   └── development.toml  # Development overrides
│
├── deploy/
│   ├── base/
│   │   ├── knative-service.yaml     # Knative Service with S3 env vars
│   │   ├── secret.yaml.example      # Secret template for credentials
│   │   └── kustomization.yaml       # Base Kustomize config
│   ├── overlays/
│   │   ├── dev/          # Development environment patches
│   │   ├── staging/      # Staging environment patches
│   │   └── prod/         # Production environment patches
│   └── flux/             # FluxCD GitRepository and Kustomization
│
├── terraform/
│   ├── main.tf           # Root module with MinIO module
│   ├── variables.tf      # Input variables
│   └── modules/minio/
│       ├── main.tf       # MinIO bucket resources
│       └── outputs.tf    # Bucket names output
│
├── tests/
│   ├── health_test.rs    # Health endpoint tests
│   ├── storage_test.rs   # S3 integration tests
│   └── common/mod.rs     # Test utilities
│
├── docker/
│   ├── otel-collector-config.yaml  # OpenTelemetry configuration
│   └── prometheus.yaml             # Prometheus config
│
├── Cargo.toml            # Rust dependencies with conditional S3
├── Dockerfile            # Multi-stage Docker build
├── docker-compose.yaml   # Local development services with MinIO
└── README.md             # This file
```

## Configuration

### Environment Variables

**Server:**
- `APP__SERVER__HOST`: Server bind address (default: 0.0.0.0)
- `APP__SERVER__PORT`: Server port (default: 8080)

**Redis:**
- `APP__REDIS__URL`: Redis connection URL (default: redis://localhost:6379)

**S3/MinIO:**
- `APP__S3__ENDPOINT`: S3 endpoint (default: http://minio:9000)
- `APP__S3__BUCKET`: Bucket name (default: data)
- `APP__S3__REGION`: AWS region (default: us-east-1)
- `AWS_ACCESS_KEY_ID`: S3 access key
- `AWS_SECRET_ACCESS_KEY`: S3 secret key

**Observability:**
- `APP__TELEMETRY__OTLP_ENDPOINT`: OpenTelemetry collector (default: http://localhost:4317)
- `APP__TELEMETRY__SERVICE_NAME`: Service name for traces (default: example-app)
- `APP__TELEMETRY__LOG_LEVEL`: Log level (default: info)
- `RUST_LOG`: Rust log filter (default: info)

### Configuration Files

**config/default.toml**
```toml
[server]
host = "0.0.0.0"
port = 8080

[redis]
url = "redis://localhost:6379"

[s3]
endpoint = "http://minio:9000"
bucket = "data"
region = "us-east-1"

[telemetry]
otlp_endpoint = "http://localhost:4317"
service_name = "example-app"
log_level = "info"
```

**config/development.toml** (environment overrides)
```toml
[server]
host = "127.0.0.1"
port = 8080

[telemetry]
log_level = "debug"
```

## API Endpoints

### Health Checks

- `GET /health/live` - Liveness probe (always 200)
- `GET /health/ready` - Readiness probe (checks Redis and S3)

### S3 Storage (if enabled)

- `POST /api/upload` - Upload object to S3
  ```json
  {
    "key": "path/to/object",
    "data": "base64-encoded-data"
  }
  ```

- `GET /api/download/:key` - Download object from S3

- `GET /api/objects` - List all objects in bucket

- `DELETE /api/delete/:key` - Delete object from S3

- `HEAD /api/stat/:key` - Get object metadata

### Metrics

- `GET /metrics` - Prometheus metrics in OpenMetrics format

## Storage Integration (S3/MinIO)

See [STORAGE.md](./STORAGE.md) for detailed S3/MinIO integration guide covering:
- Architecture and design patterns
- Configuration for MinIO and AWS S3
- Code examples for CRUD operations
- Testing with integration tests
- Terraform bucket management
- Production deployment

## Development

### Adding New Routes

Edit `src/routes.rs`:
```rust
use axum::{Router, routing::get};
use crate::handlers;

pub fn routes() -> Router {
    Router::new()
        .route("/api/new", get(handlers::new_handler))
}
```

Edit `src/handlers/api.rs`:
```rust
pub async fn new_handler(State(state): State<AppState>) -> impl IntoResponse {
    // Your handler logic
}
```

### Running Tests

```bash
# Run all tests
cargo test

# Run with output
cargo test -- --nocapture

# Run specific test
cargo test test_name

# Integration tests with services
docker-compose up -d && cargo test --test '*'
```

### Code Quality

```bash
# Format code
cargo fmt

# Lint with clippy
cargo clippy -- -D warnings

# Check documentation
cargo doc --no-deps --open
```

### Building for Production

```bash
# Build optimized binary
cargo build --release

# Build Docker image
docker build -t example-app:latest .

# Build with musl for Alpine
cargo build --release --target x86_64-unknown-linux-musl
```

## Kubernetes Configuration

### Knative Service (deploy/base/knative-service.yaml)

The service is configured with:
- Auto-scaling: min 0, max 100 replicas
- Health checks: liveness and readiness probes
- Resource limits: 512Mi memory, 1000m CPU
- CloudEvents: Full support for event-driven workloads
- S3 credentials: Mounted from Kubernetes Secret

### Environment Overlays

**dev/** - Development settings
- 1-10 replicas
- Debug logging
- MinIO endpoint

**staging/** - Staging settings
- 2-20 replicas
- Info logging
- AWS S3 with credentials from secret

**prod/** - Production settings
- 5-100 replicas
- Warn logging
- AWS S3 with secret management

Apply with:
```bash
kubectl apply -k deploy/overlays/prod
```

## FluxCD GitOps

### Initial Setup

1. Create Git repository with this template
2. Configure FluxCD to watch the repository:
   ```bash
   flux bootstrap github \
     --owner=your-org \
     --repo=your-repo \
     --personal \
     --path=clusters/production
   ```

3. Create FluxCD Kustomization:
   ```bash
   kubectl apply -f deploy/flux/git-repository.yaml
   kubectl apply -f deploy/flux/kustomization.yaml
   ```

### Automated Deployments

The `deploy/flux/image-update-automation.yaml` automatically:
- Monitors container registry for new images
- Updates image references in manifests
- Commits changes to Git
- Triggers Knative service updates

## Observability

### Jaeger Tracing

View distributed traces: http://localhost:16686

The service instruments:
- HTTP requests (Axum integration)
- Redis operations
- S3/OpenDAL operations (custom spans)
- Custom business logic spans

### Prometheus Metrics

View metrics: http://localhost:9090

Exported metrics:
- HTTP request duration and count (by method, path, status)
- Redis connection pool stats
- Custom application metrics

### Logs

Structured logging with:
- Request ID tracing
- Service context
- Correlation IDs for distributed tracing

View with:
```bash
RUST_LOG=debug cargo run
docker logs <container-id>
```

## Terraform Infrastructure

### Deploy Buckets

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

Variables:
```hcl
minio_endpoint = "http://minio:9000"
minio_access_key = "minioadmin"
minio_secret_key = "minioadmin"
```

Output:
```hcl
bucket_names = ["data", "data-staging", "data-prod"]
```

## Troubleshooting

### Redis Connection Fails
```bash
# Check Redis is running
docker-compose ps redis

# Verify connection
redis-cli -h localhost ping
```

### MinIO Access Issues
```bash
# Check MinIO is healthy
curl http://localhost:9000/minio/health/live

# Check credentials in environment
echo $AWS_ACCESS_KEY_ID
echo $AWS_SECRET_ACCESS_KEY
```

### Knative Service Not Ready
```bash
# Check service status
kubectl get ksvc example-app

# View service details
kubectl describe ksvc example-app

# Check pods
kubectl get pods -l serving.knative.dev/service=example-app

# View logs
kubectl logs -f deployment/<deployment-name>
```

### S3 Integration Tests Fail
```bash
# Ensure MinIO is running and healthy
docker-compose logs minio

# Check test output
cargo test --test '*' -- --nocapture --test-threads=1
```

## Performance Tuning

### Redis Connection Pool
Edit `src/main.rs`:
```rust
let manager = redis::aio::MultiplexedConnection::new(client);
```

### S3 Operator Configuration
Edit `src/main.rs` S3 initialization to add:
```rust
let builder = http_backend::HttpBuilder::default()
    .client(client)
    .root(&bucket);
```

### Knative Auto-scaling
Edit `deploy/base/knative-service.yaml`:
```yaml
autoscaling.knative.dev/minScale: "1"
autoscaling.knative.dev/maxScale: "100"
autoscaling.knative.dev/targetUtilizationPercentage: "70"
```

## Security

### Secret Management
- Use Kubernetes Secrets for sensitive data
- S3 credentials stored in encrypted Secret
- No hardcoded secrets in config files
- Credentials rotated via GitOps

### Container Security
- Non-root user in Dockerfile
- Read-only root filesystem
- Security context in Knative manifests
- Network policies via Istio/Cilium

### Code Security
- Dependencies: Regular `cargo audit`
- SAST: Integrated in CI with clippy
- Container scanning: Use your registry's scanner
- Supply chain: Signed commits recommended

## Contributing

See the root TEMPLATE.md for:
- How to extend the template
- Adding new configuration options
- Customizing for your team

## License

MIT License - See LICENSE file

## Support

For issues or questions:
1. Check [STORAGE.md](./STORAGE.md) for S3-specific issues
2. Review [GETTING_STARTED.md](./GETTING_STARTED.md) for setup help
3. Check [TEMPLATE.md](./TEMPLATE.md) for template structure
4. Review service logs: `kubectl logs -f svc/example-app`


