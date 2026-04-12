# Quick Reference: Features at a Glance

## HTTP API Endpoints
| Endpoint | Method | Purpose | Required |
|----------|--------|---------|----------|
| `/health/live` | GET | Liveness probe (always succeeds) | Required |
| `/health/ready` | GET | Readiness probe (checks Redis) | Required |
| `/api/v1/hello` | GET | Example versioned endpoint | Example |
| `/` | POST | CloudEvents sink (Kafka, HTTP sources) | Built-in |
| `/api/v1/storage/example` | POST | S3 storage demo | Optional (S3 feature) |
| `/metrics` | GET | Prometheus metrics | Built-in |
| `/swagger-ui` | GET | OpenAPI documentation | Built-in |

## Core Features

### Observability (Built-in)
- **Distributed Tracing**: OpenTelemetry → Jaeger (B3 headers for Knative)
- **Metrics**: Prometheus-compatible HTTP request metrics
- **Logging**: Structured JSON logs with trace ID correlation
- **Alerting**: Examples for Slack, PagerDuty

### Storage
- **S3-Compatible** (Optional, OpenDAL): MinIO, AWS S3, GCS
- **Redis** (Required): Caching, sessions, temporary data

### Database
- **PostgreSQL**: Managed via CloudNativePG operator (not app-integrated)
  - HA with multi-instance clustering
  - Automated backups with PITR
  - Monitoring and alerting

### Events & Messaging
- **Kafka**: Event source via Knative Eventing
- **CloudEvents**: Automatic format conversion
- **DLQ**: Dead Letter Queue for failed events
- **Consumer Scaling**: Automatic to match partitions

### Deployment & Infrastructure
- **Knative Serving**: Auto-scaling (min 1, max 100, scale-to-zero)
- **FluxCD**: Git-driven deployment
- **Docker**: Multi-stage, optimized builds
- **Kustomize**: Base + overlays (dev/staging/prod)

## Configuration

### Three-Tier Hierarchy
1. Environment variables (`APP__*` prefix) - Highest priority
2. Environment-specific TOML files (`config/{env}.toml`)
3. Hardcoded defaults - Lowest priority

### Configurable Parameters
- Server: `host`, `port` (default: 0.0.0.0:8080)
- Redis: `url` (required)
- Telemetry: `otlp_endpoint`, `service_name`, `log_level`
- S3: `endpoint`, `bucket`, `region` (if S3 feature enabled)

## Testing

### Test Types
- **Unit Tests**: `#[test]`, `#[tokio::test]`
- **Integration Tests**: With Redis, S3 (optional), PostgreSQL
- **E2E Tests**: Kind cluster + Kubernetes deployment scripts

### Development Environment
```bash
make dev-up      # Start Kind + Knative + Redis + MinIO + Kafka + PostgreSQL
make dev-logs    # Follow service logs
cargo test       # Run all tests
```

## Technology Stack Summary

| Category | Technology |
|----------|------------|
| Language | Rust 1.92+ |
| Runtime | Tokio 1.41+ |
| Web Framework | Axum 0.8 |
| Observability | OpenTelemetry 0.31 + Jaeger + Prometheus |
| Storage | Redis 0.24, OpenDAL 0.55 |
| Database | PostgreSQL (CloudNativePG 1.28.0) |
| Events | Kafka + Knative Eventing |
| Deployment | Knative Serving + FluxCD + Docker |
| IaC | Kustomize + YAML |

## Key Characteristics

### What It Does Well
- Enterprise observability (traces, metrics, logs)
- Kubernetes-native deployment (Knative)
- GitOps infrastructure (FluxCD)
- Event-driven architectures (Kafka)
- Production database with HA/backups
- Cloud-agnostic storage (S3 abstraction)

### What It Doesn't Include
- Application-level database integration (ORM, migrations)
- Authentication/Authorization (JWT, OAuth2)
- Kafka event publishing (consume-only)
- Business logic (intentionally minimal)
- Multi-cluster deployment patterns

## Production Readiness Checklist

- ✅ Security hardening (non-root, read-only FS, secrets management)
- ✅ High availability (graceful shutdown, health checks, failover)
- ✅ Disaster recovery (automated backups, PITR, recovery docs)
- ✅ Comprehensive observability (tracing, metrics, logging)
- ✅ Infrastructure as Code (GitOps, immutable)
- ✅ Testing & quality (unit, integration, E2E)
- ✅ Documentation (architecture, deployment, operations)

## Getting Started

### Generate from Template
```bash
cargo generate --git https://github.com/your-org/rust-knative-flux-template
```

### Select Features
- **Project name**: Your service name
- **S3 storage**: true/false (optional)
- **Image updates**: true/false (FluxCD automation)
- **Namespace**: Kubernetes namespace
- **GitHub**: org, repo, branch

### Minimal Development Setup
```bash
# Start full development environment
make dev-up

# Build and test
cargo build
cargo test

# Run locally
cargo run

# View observability
# Jaeger: http://localhost:16686
# Prometheus: http://localhost:9090
```

## Documentation Files

- **ARCHITECTURE.md** - System design and component breakdown
- **DEPLOYMENT.md** - Production deployment procedures
- **MONITORING.md** - Observability setup and dashboards
- **KAFKA_EVENTING.md** - Event-driven architecture guide
- **POSTGRES.md** - Database operations and backup/recovery
- **SECURITY.md** - Security hardening guide
- **TESTING.md** - Testing strategy and examples
- **TROUBLESHOOTING.md** - Operations runbooks
- **FEATURE_ANALYSIS.md** - This comprehensive analysis
