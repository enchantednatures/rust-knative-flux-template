# Rust Knative FluxCD Template

A production-ready template for building Rust microservices with Axum, deployed to Kubernetes via Knative Serving and managed by FluxCD using the "repo per app" pattern.

## Features

- **Rust + Axum**: Modern async web framework with type safety
- **Knative Serving**: Serverless on Kubernetes with auto-scaling
- **FluxCD GitOps**: Infrastructure as Code with continuous deployment
- **OpenTelemetry**: Distributed tracing with Knative B3 header propagation
- **Redis**: Multiplexed async connections (no pooling overhead)
- **Configuration**: Layered with Figment (files → env vars → defaults)
- **Docker**: Multi-stage Alpine build with static musl linking (15-25 MB images)
- **Health Probes**: Liveness and readiness checks with Redis validation
- **API Docs**: OpenAPI/Swagger with Utoipa
- **Tests**: Integration tests with Redis service
- **CI/CD**: GitHub Actions with Docker build, scan, and Flux-compatible tagging

## Quick Start

### Prerequisites

- Rust 1.75+ (installed via rustup)
- Docker & Docker Compose
- Redis (via docker-compose)
- Kubectl (for Kubernetes deployment)
- Flux CLI (for FluxCD operations)

### Local Development

```bash
# Clone the repository
git clone https://github.com/your-org/rust-knative-flux-template
cd rust-knative-flux-template

# Start local services (Redis, OTel Collector, Jaeger)
docker compose up -d

# Run tests (requires Redis running)
cargo test

# Run the application
cargo run

# Access the service
curl http://localhost:8080/health/live
curl http://localhost:8080/health/ready
curl http://localhost:8080/api/v1/hello?name=Rust

# View traces
open http://localhost:16686  # Jaeger UI
open http://localhost:9090   # Prometheus UI
```

### Configuration

The application uses **layered configuration** with this priority:

1. **Environment Variables** (highest - `APP__*` prefix)
2. **Config Files** (config/{env}.toml)
3. **Defaults** (hardcoded in code)

#### Example Environment Variables

```bash
# Server configuration
APP__SERVER__PORT=9000
APP__SERVER__HOST=127.0.0.1

# Redis configuration
APP__REDIS__URL="redis://:password@redis-host:6379/0"

# Telemetry configuration
APP__TELEMETRY__OTLP_ENDPOINT="http://otel-collector:4317"
APP__TELEMETRY__SERVICE_NAME="my-service"
APP__TELEMETRY__LOG_LEVEL="debug"

# Application environment
APP_ENV=production
```

Environment variables are validated **early** in `main.rs`, so the application will fail to start if required values are missing.

## Architecture

### File Structure

```
rust-knative-flux-template/
├── src/
│   ├── config.rs              # Figment configuration with validation
│   ├── error.rs               # Unified error handling
│   ├── state.rs               # AppState with DI pattern
│   ├── observability.rs       # OTel + B3 propagation setup
│   ├── handlers/
│   │   ├── health.rs          # /health/live, /health/ready
│   │   └── api.rs             # Example /api/v1/hello endpoint
│   ├── routes.rs              # Router composition
│   ├── lib.rs                 # Library root
│   └── main.rs                # Entrypoint with graceful shutdown
├── tests/
│   ├── health_test.rs         # Integration tests
│   └── common/mod.rs          # Test utilities
├── config/
│   ├── default.toml
│   └── development.toml
├── deploy/
│   ├── base/
│   │   ├── knative-service.yaml
│   │   ├── secret.yaml.example
│   │   └── kustomization.yaml
│   ├── overlays/
│   │   ├── dev/
│   │   ├── staging/
│   │   └── prod/
│   └── flux/
│       ├── git-repository.yaml
│       ├── image-repository.yaml
│       ├── image-policy.yaml
│       ├── kustomization.yaml
│       └── image-update-automation.yaml
├── docker/
│   ├── otel-collector-config.yaml
│   └── prometheus.yaml
├── .github/workflows/ci.yaml   # GitHub Actions pipeline
├── Dockerfile                  # Multi-stage Alpine build
├── docker-compose.yaml         # Local dev environment
└── Cargo.toml                  # Dependencies
```

### Dependency Injection Pattern

The application uses **explicit dependency injection** for testability:

```rust
// In main.rs
let redis_client = redis::Client::open(&config.redis.url)?;
let redis_conn = client.get_multiplexed_async_connection().await?;
let state = AppState::new(redis_conn);

// AppState::new() accepts the connection, doesn't create it
impl AppState {
    pub fn new(redis: MultiplexedConnection) -> Self {
        Self { redis }
    }
}
```

This makes it easy to:
- Test with mock connections
- Swap Redis for another data store
- Validate connections before startup

### Trace Propagation (Critical for Knative)

Knative infrastructure uses **Zipkin B3 headers** for distributed tracing. Without B3 support, your application traces will be **disconnected** from Knative's infrastructure traces.

This template uses a **composite propagator**:

```rust
let composite_propagator = TextMapCompositePropagator::new(vec![
    Box::new(TraceContextPropagator::new()),  // W3C standard
    Box::new(B3Propagator::new()),            // Knative B3
]);
global::set_text_map_propagator(composite_propagator);
```

This ensures traces propagate correctly through:
```
External Client → Knative Ingress → Activator → Queue-Proxy → Your App
```

### Health Probes

#### Liveness Probe: `/health/live`

- **Returns**: 200 OK
- **Checks**: None (just confirms process is running)
- **Action on Failure**: Kubernetes restarts the pod

#### Readiness Probe: `/health/ready`

- **Returns**: 200 OK if Redis PING succeeds, 503 otherwise
- **Checks**: Redis connectivity
- **Action on Failure**: Kubernetes removes pod from Service endpoints (no restart)

```bash
curl http://localhost:8080/health/live
# {"status":"alive"}

curl http://localhost:8080/health/ready
# {"status":"ready"} or {"status":"redis unavailable: ..."}
```

## Docker Build

The Dockerfile uses a **multi-stage build** with Alpine Linux:

### Stage 1: Build
- Uses `rust:1.83-alpine` with musl-dev
- Compiles to `x86_64-unknown-linux-musl` target
- Creates a fully static binary (no dependencies needed)

### Stage 2: Runtime
- Uses `alpine:3.21` as runtime (15-25 MB image)
- Runs as non-root user (uid 10001)
- Read-only filesystem for security
- Health check included

```bash
# Build locally
docker build -t rust-service:latest .

# Test the image
docker run -e APP__REDIS__URL=redis://host.docker.internal:6379 rust-service:latest

# Check image size
docker images rust-service:latest
# Should be ~20 MB
```

## Kubernetes Deployment

### 1. Create the Secret

```bash
# Copy the example secret
cp deploy/base/secret.yaml.example deploy/base/secret.yaml

# Edit with your Redis URL
nano deploy/base/secret.yaml

# Create the secret (don't commit to git!)
kubectl apply -f deploy/base/secret.yaml

# Verify
kubectl get secret rust-service-secrets
```

### 2. Deploy with Kustomize

```bash
# Deploy to production
kubectl apply -k deploy/overlays/prod

# Deploy to staging
kubectl apply -k deploy/overlays/staging

# Deploy to development
kubectl apply -k deploy/overlays/dev
```

### 3. Verify Deployment

```bash
# Check Knative Service
kubectl get ksvc rust-service

# View logs
kubectl logs -l app=rust-service -f

# Check readiness
kubectl get pod -l app=rust-service -o wide

# Port-forward for local testing
kubectl port-forward svc/rust-service 8080:8080
curl http://localhost:8080/api/v1/hello
```

## FluxCD Setup

### 1. Bootstrap Flux (in your infrastructure repo)

```bash
flux bootstrap github \
  --owner=your-org \
  --repo=infrastructure \
  --branch=main \
  --path=./clusters/prod
```

### 2. Create Secret for Container Registry (if private)

```bash
kubectl create secret docker-registry ghcr-credentials \
  --docker-server=ghcr.io \
  --docker-username=<username> \
  --docker-password=<token> \
  -n flux-system
```

### 3. Apply Flux Resources

```bash
# Create the resources
kubectl apply -f deploy/flux/git-repository.yaml
kubectl apply -f deploy/flux/image-repository.yaml
kubectl apply -f deploy/flux/image-policy.yaml
kubectl apply -f deploy/flux/kustomization.yaml

# (Optional) ImageUpdateAutomation in infrastructure repo
kubectl apply -f deploy/flux/image-update-automation.yaml
```

### 4. Monitor Flux Reconciliation

```bash
# Watch GitRepository sync
flux get source git rust-service -w

# Watch ImageRepository scans
flux get image all -w

# Watch Kustomization reconciliation
flux get kustomization rust-service -w

# View logs
flux logs --follow --all-namespaces
```

## CI/CD Pipeline

The GitHub Actions workflow (`.github/workflows/ci.yaml`) performs:

1. **Lint & Format** (Clippy, rustfmt)
2. **Tests** (with Redis service)
3. **Build & Push** Docker image
4. **Security Scan** (Trivy)

### Image Tagging Strategy

The pipeline tags images for Flux compatibility:

| Tag Pattern | Example | Purpose |
|-------------|---------|---------|
| `sha-{short}` | `sha-a1b2c3d` | Git commit reference (used by Flux policy) |
| `ts-{datetime}` | `ts-20241221150000` | Timestamp for ordering |
| `{branch}` | `main` | Branch name |
| `latest` | `latest` | Latest on main branch |
| `{version}` | `1.0.0` | SemVer for release tags |

The Flux `ImagePolicy` selects the latest `sha-*` tag for continuous deployment.

## Local Development with Traces

### Starting the Stack

```bash
# Start all services
docker compose up -d

# Watch logs
docker compose logs -f app

# Stop everything
docker compose down -v
```

### Viewing Traces

1. **Jaeger UI**: http://localhost:16686
2. **Prometheus**: http://localhost:9090
3. **Swagger UI**: http://localhost:8080/swagger-ui/

### Testing B3 Propagation

```bash
# Simulate a request from Knative infrastructure with B3 headers
curl -H "X-B3-TraceId: 80f198ee56343ba864fe8b2a57d3eff7" \
     -H "X-B3-SpanId: e457b5a2e4d86bd1" \
     -H "X-B3-Sampled: 1" \
     http://localhost:8080/api/v1/hello

# In Jaeger, search for trace ID: 80f198ee56343ba864fe8b2a57d3eff7
# Your app's spans should appear under this trace
```

## Configuration Reference

### Config Files

**default.toml** - Hardcoded defaults
```toml
[server]
host = "0.0.0.0"
port = 8080

[redis]
url = "redis://localhost:6379"

[telemetry]
service_name = "rust-service"
log_level = "info"
```

**development.toml** - Development overrides
```toml
[telemetry]
service_name = "rust-service-dev"
log_level = "debug"
otlp_endpoint = "http://localhost:4317"
```

### Environment Variable Mapping

| Config Path | Env Var |
|------------|---------|
| `server.host` | `APP__SERVER__HOST` |
| `server.port` | `APP__SERVER__PORT` |
| `redis.url` | `APP__REDIS__URL` |
| `telemetry.otlp_endpoint` | `APP__TELEMETRY__OTLP_ENDPOINT` |
| `telemetry.service_name` | `APP__TELEMETRY__SERVICE_NAME` |
| `telemetry.log_level` | `APP__TELEMETRY__LOG_LEVEL` |

## Dependencies

### Core
- **axum**: Web framework
- **tokio**: Async runtime
- **serde**: Serialization
- **figment**: Configuration management

### Observability
- **opentelemetry**: Tracing SDK
- **opentelemetry-otlp**: OTLP exporter
- **opentelemetry-zipkin**: B3 propagation (Knative)
- **tracing**: Structured logging
- **tracing-subscriber**: Log formatting

### Data
- **redis**: Redis client (multiplexed async connection)

### API
- **utoipa**: OpenAPI documentation

## Security Considerations

1. **Non-root user**: Runs as `appuser` (uid 10001)
2. **Read-only filesystem**: Pod spec includes `readOnlyRootFilesystem: true`
3. **Secrets**: Managed via K8s Secret references, never in environment by default
4. **RBAC**: Apply proper namespace-level and pod-level RBAC policies
5. **Network Policies**: Consider implementing network policies in your cluster

## Troubleshooting

### Application fails to start with "Configuration error"

Check that all required environment variables are set:
```bash
echo $APP__REDIS__URL
echo $APP__SERVER__PORT
```

The application performs early validation and fails fast if critical config is missing.

### Readiness probe failing (503)

The readiness probe checks Redis connectivity:
```bash
# Check Redis is running
redis-cli ping

# Check Redis URL is correct
echo $APP__REDIS__URL

# Manually test Redis connection
redis-cli -u redis://localhost:6379 PING
```

### Traces not appearing in Jaeger

1. Check OTLP endpoint is configured:
   ```bash
   echo $APP__TELEMETRY__OTLP_ENDPOINT
   ```

2. Verify OTel collector is running:
   ```bash
   docker compose logs otel-collector
   ```

3. Check network connectivity between app and collector

4. Verify B3 headers are being propagated:
   ```bash
   # Check logs for trace IDs
   docker compose logs app | grep "trace"
   ```

### High memory usage

The multiplexed Redis connection is efficient. If memory is high:
- Check if you're accumulating connections somehow
- Verify Redis `PING` in readiness probe is working
- Check application logs for errors

## Contributing

1. Create a feature branch
2. Make changes
3. Run tests locally: `cargo test`
4. Format: `cargo fmt`
5. Lint: `cargo clippy`
6. Commit and push
7. Create a Pull Request

## License

MIT License - See LICENSE file for details

## Resources

- [Rust Book](https://doc.rust-lang.org/book/)
- [Axum Documentation](https://docs.rs/axum/)
- [Knative Serving](https://knative.dev/docs/serving/)
- [FluxCD Documentation](https://fluxcd.io/docs/)
- [OpenTelemetry](https://opentelemetry.io/)
- [Figment Configuration](https://docs.rs/figment/)

## Support

For issues or questions:
- Check the [Troubleshooting](#troubleshooting) section
- Review [GitHub Issues](https://github.com/your-org/rust-knative-flux-template/issues)
- Create a new issue with:
  - Steps to reproduce
  - Expected vs actual behavior
  - Environment (Rust version, Kubernetes version, etc.)
