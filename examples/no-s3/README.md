# no-s3

A production-ready Rust microservice template for Knative Serverless and FluxCD GitOps, with optional S3-compatible storage support (MinIO/AWS S3).


## Features

- 🚀 **Knative Serverless**: Auto-scaling HTTP service with CloudEvents support
- 🔍 **Observability**: OpenTelemetry instrumentation with Jaeger and Prometheus
- 🔄 **GitOps Ready**: FluxCD manifests for automated deployments
- 🏗️ **Infrastructure as Code**: Terraform configuration for deployments
- 🧪 **Fully Tested**: Integration tests with Redis
- 📝 **Type-Safe**: Rust with strict compiler checks
- ⚡ **Fast**: Built on Tokio async runtime

## Quick Start

### Local Development

1. **Prerequisites**
   - Docker & Docker Compose
   - Rust 1.92+

2. **Start Local Services**
   ```bash
   docker-compose up -d
   ```

   This starts:
   - Redis (port 6379)
   - Jaeger tracing (port 16686)
   - Prometheus metrics (port 9090)
   - OpenTelemetry Collector

3. **Run the Service**
   ```bash
   export APP__SERVER__PORT=8080
   export APP__REDIS__URL=redis://localhost:6379
   cargo watch -q -c -w src -x run
   ```

4. **Health Check**
   ```bash
   curl http://localhost:8080/health/live
   curl http://localhost:8080/health/ready
   ```

5. **View Traces & Metrics**
   - Jaeger: http://localhost:16686
   - Prometheus: http://localhost:9090

### Kubernetes Deployment

```bash
# Development
kubectl apply -k deploy/overlays/dev

# Staging
kubectl apply -k deploy/overlays/staging

# Production
kubectl apply -k deploy/overlays/prod
```

## Project Structure

```
no-s3/
├── src/
│   ├── main.rs           # Application entry point
│   ├── lib.rs            # Module exports
│   ├── config.rs         # Configuration
│   ├── state.rs          # AppState with Redis
│   ├── error.rs          # Error handling
│   ├── observability.rs  # OpenTelemetry setup
│   ├── routes.rs         # Route definitions
│   ├── handlers/
│   │   ├── api.rs        # API handlers
│   │   ├── health.rs     # Health check endpoints
│   │   └── mod.rs        # Handler exports
│
├── config/
│   ├── default.toml      # Default configuration
│   └── development.toml  # Development overrides
│
├── deploy/
│   ├── base/
│   │   ├── knative-service.yaml     # Knative Service
│   │   └── kustomization.yaml       # Base Kustomize config
│   ├── overlays/
│   │   ├── dev/          # Development environment
│   │   ├── staging/      # Staging environment
│   │   └── prod/         # Production environment
│   └── flux/             # FluxCD configuration
│
├── tests/
│   ├── health_test.rs    # Health endpoint tests
│   └── common/mod.rs     # Test utilities
│
├── docker/
│   ├── otel-collector-config.yaml  # OpenTelemetry config
│   └── prometheus.yaml             # Prometheus config
│
├── Cargo.toml            # Rust dependencies
├── Dockerfile            # Multi-stage Docker build
├── docker-compose.yaml   # Local development services
└── README.md             # This file
```

## Configuration

### Environment Variables

- `APP__SERVER__HOST`: Bind address (default: 0.0.0.0)
- `APP__SERVER__PORT`: Server port (default: 8080)
- `APP__REDIS__URL`: Redis URL (default: redis://localhost:6379)
- `RUST_LOG`: Log filter (default: info)

### API Endpoints

- `GET /health/live` - Liveness probe
- `GET /health/ready` - Readiness probe (checks Redis)
- `GET /metrics` - Prometheus metrics

## Development

```bash
# Format
cargo fmt

# Lint
cargo clippy -- -D warnings

# Test
cargo test

# Run
cargo run
```

## Kubernetes Deployment

Apply manifests with:
```bash
kubectl apply -k deploy/overlays/prod
```

## License

MIT License - See LICENSE file


