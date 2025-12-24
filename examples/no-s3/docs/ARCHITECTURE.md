# Architecture Guide

This document explains the system architecture, design decisions, and component interactions in example-app.

## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     Client Requests                             │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│              Knative Service (Auto-scaling)                      │
│  - Min/Max replicas                                             │
│  - Automatic scale-to-zero                                      │
│  - Traffic splitting (canary/blue-green)                        │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│         Axum Web Framework + Tokio Runtime                       │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ HTTP Handlers                                            │   │
│  │  - Health checks (/health/*)                            │   │
│  │  - API endpoints (/api/*)                               │   │
│  │  - Metrics (/metrics)                                  │   │
│  └──────────────────────────────────────────────────────────┘   │
└────────────────────────────┬────────────────────────────────────┘
                             │
                    ┌────────┴────────┐
                    │                 │
                    ▼                 ▼
        ┌─────────────────────┐   ┌──────────────────┐
        │   AppState          │   │ OpenTelemetry    │
        │ ┌─────────────────┐ │   │ ┌──────────────┐ │
        │ │ Redis Client    │ │   │ │ Tracing      │ │
        │ └─────────────────┘ │   │ ├──────────────┤ │
        └─────────────────────┘   └──────────────────┘
                    │                 │
        ┌───────────┘                 └──────────────┐
        │                                            │
        ▼                                            ▼
  ┌──────────────┐                         ┌──────────────────┐
  │ Redis        │                         │ OpenTelemetry    │
  │ (Sessions/   │                         │ Collector        │
  │  Cache)      │                         │                  │
  └──────────────┘                         └────────┬─────────┘
                                                   │
                                  ┌────────────────┼────────────────┐
                                  │                │                │
                                  ▼                ▼                ▼
                            ┌──────────┐    ┌──────────┐    ┌────────────┐
                            │ Jaeger   │    │Prometheus│    │ Log Store  │
                            │ (Traces) │    │(Metrics) │    │ (Loki/ELK) │
                            └──────────┘    └──────────┘    └────────────┘

```

## Component Breakdown

### Axum Web Framework

The application is built on **Axum**, a fast, ergonomic web framework:
- Type-safe routing
- Extractors for dependency injection (path params, query strings, state)
- Tower middleware support
- Excellent error handling with custom responses

**Location**: `src/main.rs`, `src/routes.rs`, `src/handlers/`

### AppState

Central application state shared across all handlers:

```rust
pub struct AppState {
    pub redis: MultiplexedConnection,
    
}
```

This allows:
- Shared Redis connection pool
- 
- Dependency injection via `State` extractor
- Easy testing with mock state

**Location**: `src/state.rs`

### Configuration Management

Three-tier configuration hierarchy:
1. **Environment Variables** (highest priority): `APP__SERVER__PORT=8080`
2. **Environment-Specific File**: `config/{env}.toml` (e.g., `config/development.toml`)
3. **Default File** (lowest priority): `config/default.toml`

Configuration is loaded at startup and immutable during runtime.

**Location**: `src/config.rs`

### OpenTelemetry Integration

Comprehensive observability stack:

- **Tracing**: All requests generate distributed traces with context propagation
  - B3 Propagation for Knative compatibility
  - Custom spans for business logic
  - Automatic HTTP/Redis tracing

- **Metrics**: Prometheus-compatible metrics
  - HTTP request latency (histograms)
  - Request count (counters)
  - Custom application metrics

- **Logging**: Structured JSON logs with context
  - Correlation IDs from traces
  - Severity levels
  - Contextual fields

All telemetry flows to OpenTelemetry Collector, which routes to:
- **Jaeger** for distributed tracing
- **Prometheus** for metrics
- **Loki/ELK** for centralized logging

**Location**: `src/observability.rs`



### Request Lifecycle

```
1. Client Request
   │
   ▼
2. Knative Ingress (LoadBalancer/Ingress)
   │
   ▼
3. Axum Router
   │
   ├─ Extract path/query params
   ├─ Extract State (AppState)
   ├─ Initialize trace span
   │
   ▼
4. Handler Execution
   │
   ├─ Validate input
   ├─ Access Redis/
   ├─ Create trace spans
   │
   ▼
5. Response Generation
   │
   ├─ Serialize response
   ├─ Record metrics
   ├─ Emit trace spans
   │
   ▼
6. HTTP Response to Client
```

## Design Decisions

### Why Knative Serving?

- **Serverless**: Pay only for actual usage, automatic scale-to-zero
- **Auto-scaling**: Handles traffic spikes without pre-provisioning
- **Revision Management**: Easy canary deployments and traffic splitting
- **CloudEvents Support**: First-class support for event-driven architectures
- **Industry Standard**: Used by Google Cloud Run, IBM Cloud Functions, etc.

### Why FluxCD for GitOps?

- **Declarative**: Infrastructure as Code in Git
- **Automated**: Changes sync automatically to cluster
- **Auditable**: Full Git history of infrastructure changes
- **Multi-tenancy**: Separate namespaces per team/app
- **Image Automation**: Auto-update image references on new builds

### Why OpenDAL for Storage Abstraction?

- **Provider Agnostic**: Same code works with any S3-compatible service
- **Reduced Vendor Lock-in**: Easy migration from MinIO to AWS S3
- **Ergonomic API**: Rust futures-based, async/await friendly
- **Retry Policies**: Built-in retry logic with exponential backoff
- **Production Ready**: Used by Apache projects

### Why Redis?

- **Fast**: In-memory, nanosecond latency
- **Versatile**: Caching, sessions, queues, pub/sub
- **Clustering**: High availability via Redis Cluster or Sentinel
- **Simple**: Easy setup and monitoring

### Configuration Hierarchy

Environment variables override files because:
- **Flexibility**: Different configs per environment without rebuilding
- **Security**: Secrets (credentials) via env vars, never in code/files
- **Kubernetes Native**: ConfigMaps and Secrets map naturally to env vars

## Scaling Behavior

### Knative Auto-scaling

```
Traffic Detection
    │
    ├─ Measure: Requests per second, concurrency
    │
    ▼
Calculate Desired Replicas
    │
    ├─ Formula: current_concurrency / target_concurrency × current_replicas
    │
    ▼
Scale Pods
    │
    ├─ Min: 1 (or 0 for serverless)
    ├─ Max: Configured limit (e.g., 100)
    │
    ▼
Monitor and Adjust
```

**Configuration** (in `deploy/base/knative-service.yaml`):
```yaml
autoscaling.knative.dev/minScale: "1"
autoscaling.knative.dev/maxScale: "100"
autoscaling.knative.dev/targetUtilizationPercentage: "70"
```

### Startup Sequence

1. **Cold Start**: 
   - Knative creates pod from image
   - Application initializes (parse config, connect to Redis)
   - Health check passes (/health/ready)
   - Pod marked ready for traffic

2. **Warm Start**: 
   - Existing pod receives request
   - ~1-5ms response time (depending on operation)

3. **Scale-to-Zero**:
   - If no requests for 5+ minutes
   - Knative terminates pods
   - Next request triggers cold start
   - Graceful shutdown closes connections

## Dependencies

### External Services

| Service | Purpose | Criticality | Local Dev | Production |
|---------|---------|-------------|-----------|------------|
| Kubernetes | Container orchestration | REQUIRED | Kind (tests) | EKS/GKE/etc |
| Knative | Serverless runtime | REQUIRED | Included in Kind | Pre-installed |
| Redis | Caching/sessions | REQUIRED | docker-compose | AWS ElastiCache/Redis Enterprise |
| OpenTelemetry | Observability | OPTIONAL | docker-compose | Dedicated collector | |
| OpenTelemetry | Observability | OPTIONAL | docker-compose | Dedicated collector |
| Jaeger | Distributed tracing | OPTIONAL | docker-compose | Cloud provider/self-hosted |
| Prometheus | Metrics collection | OPTIONAL | docker-compose | Cloud provider/self-hosted |

### Rust Dependencies

Key crates:
- **axum**: Web framework
- **tokio**: Async runtime
- **redis**: Redis client
- 
- **opentelemetry**: Telemetry SDK
- **tracing**: Structured logging
- **serde**: Serialization
- **serde_json**: JSON handling

See `Cargo.toml` for complete dependency tree.

## Data Flow Examples

### Health Check


```
Client: GET /health/live
               │
               ▼
        Knative Service
        (Load Balancer)
               │
               ▼
        Axum Router
        matches: /health/live
               │
               ▼
        handlers::health::liveness
               │
               ├─ Return 200 OK (no dependencies)
               │
               ▼
        HTTP 200 OK
        (Always succeeds, even if Redis is down)
```

### Health Check with Dependency Check

```
Client: GET /health/ready
               │
               ▼
        handlers::health::readiness
               │
               ├─ Check Redis connection
               │  └─ PING command
               │     └─ If fails, return 503 unavailable
               │
               ▼
        HTTP 200 OK (if Redis healthy)
        HTTP 503 Service Unavailable (if Redis unhealthy)
               │
               ▼
        Knative uses for readiness probe
        - Only sends traffic to ready pods
        - Terminates pods if readiness fails
```



## Error Handling Strategy

The application uses a custom `AppError` type for consistent error handling:

```rust
pub enum AppError {
    NotFound(String),
    BadRequest(String),
    InternalServerError(String),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, body) = match self {
            AppError::NotFound(msg) => (StatusCode::NOT_FOUND, msg),
            AppError::BadRequest(msg) => (StatusCode::BAD_REQUEST, msg),
            AppError::InternalServerError(msg) => (StatusCode::INTERNAL_SERVER_ERROR, msg),
        };
        
        (status, Json(json!({"error": body}))).into_response()
    }
}
```

Benefits:
- Consistent error format
- Automatic HTTP status codes
- Logged with context
- Traced in distributed traces

## State Machine: Pod Lifecycle

```
┌──────────────────┐
│  Pod Created     │
│  (Cold Start)    │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│ App Initializing │
│ - Parse config   │
│ - Connect Redis  │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│ Readiness Check  │
│ (health/ready)   │
└────────┬─────────┘
         │
         ├─ FAIL ──────────────┐
         │                     │
         ▼                     ▼
    Ready to Receive      Crash/Restart
    Traffic               (kubelet restarts)
         │
         ├─ Process requests
         │  (warm phase)
         │
         ├─ No traffic
         │  for 5 minutes
         │
         ▼
    Scale-to-Zero
    (Knative terminates)
         │
         ▼
    SIGTERM Signal
    (30s grace period)
         │
         ├─ Close connections
         ├─ Finish in-flight requests
         │
         ▼
    Pod Terminated
```

## Security Boundaries

```
┌─────────────────────────────────────────────────┐
│ Kubernetes Network Boundary                     │
│  - Enforced via NetworkPolicy                   │
│  - mTLS via service mesh (optional)             │
│                                                  │
│  ┌──────────────────────────────────────────┐   │
│  │ Pod Security Boundary                    │   │
│  │  - Non-root user                         │   │
│  │  - Read-only root filesystem             │   │
│  │  - Seccomp/AppArmor profiles             │   │
│  │                                          │   │
│  │  ┌────────────────────────────────────┐ │   │
│  │  │ Application Security Boundary      │ │   │
│  │  │  - Input validation                │ │   │
│  │  │  - Error handling (no secrets)     │ │   │
│  │  │  - Dependency scanning (audit)     │ │   │
│  │  └────────────────────────────────────┘ │   │
│  └──────────────────────────────────────────┘   │
│                                                  │
│  External Dependencies (Encrypted)              │
│  - Redis: Optional TLS                          │
│  - OpenTelemetry: OTLP/gRPC |
└─────────────────────────────────────────────────┘
```

See `docs/SECURITY.md` for detailed security guidance.

## Performance Characteristics

| Operation | Expected Latency | Bottleneck |
|-----------|------------------|-----------|
| Health check (/health/live) | <1ms | Network RTT |
| Health ready (/health/ready) | 5-10ms | Redis PING |
| Trace processing | <1ms | In-process |
| Metrics recording | <1ms | In-process |

Optimization techniques:
- Connection pooling (Redis, )
- Async/await with Tokio
- Minimal allocations in hot paths
- Zero-copy where possible
- Trace sampling in production

## Testing Architecture

```
Unit Tests
  │
  ├─ No external dependencies
  └─ Run in CI/CD

Integration Tests
  │
  ├─ Docker services (Redis, )
  └─ Full handler testing

E2E Tests
  │
  ├─ Kind Kubernetes cluster
  ├─ Deploy via Kustomize/FluxCD
  └─ End-to-end workflow verification
```

See `docs/TESTING.md` for detailed testing strategy.

## Deployment Architecture

```
Git Repository
    │
    ├─ Application code
    ├─ Kubernetes manifests (deploy/)
    ├─ Configuration (config/)
    │
    ▼
FluxCD GitRepository
    │
    ├─ Polls Git every 1 minute
    │
    ▼
FluxCD Kustomization
    │
    ├─ Applies Kustomize patches
    ├─ Template substitution
    │
    ▼
Kubernetes Apply
    │
    ├─ Create Knative Service
    ├─ Create ConfigMaps/Secrets
    ├─ Create RBAC resources
    │
    ▼
Knative Controller
    │
    ├─ Create Deployment
    ├─ Create Service
    ├─ Manage revisions
    │
    ▼
Pods Running on Nodes
```

See `docs/DEPLOYMENT.md` for detailed deployment procedures.

## Next Steps

- **For Developers**: Read `docs/DEVELOPMENT.md` for local setup
- **For Operators**: Read `docs/DEPLOYMENT.md` and `docs/MONITORING.md`
- **For Security**: Read `docs/SECURITY.md` for hardening
- **For Troubleshooting**: Read `docs/TROUBLESHOOTING.md`
