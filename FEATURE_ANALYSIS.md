# Rust Knative Flux Template - Current Features & Capabilities Analysis

## Executive Summary

This is a production-ready **Rust microservice template** designed for cloud-native deployment on Kubernetes using **Knative Serving** and **FluxCD GitOps**. It includes comprehensive observability, optional S3 storage support, PostgreSQL database integration, and Kafka event streaming capabilities.

**Core Purpose**: Accelerate development of serverless microservices with best practices for observability, deployment, and infrastructure-as-code.

---

## 1. What This Template Currently Does

### Core Functionality
- **Serverless Microservice Framework**: Ready-to-deploy async Rust web service
- **High-Performance Async Runtime**: Built on Tokio with Axum web framework
- **Kubernetes-Native**: Designed specifically for Knative Serving with auto-scaling
- **Distributed Tracing**: Full observability with OpenTelemetry integration
- **Infrastructure as Code**: GitOps deployment with FluxCD
- **Event-Driven Architecture**: Support for CloudEvents and Kafka integration
- **Optional Object Storage**: S3-compatible storage abstraction via OpenDAL

### Template Nature
- **Cargo Generate Template**: Customizable project generation with user prompts
- **Liquid Template Syntax**: Conditional feature inclusion during generation
- **Multi-Environment**: Separate configurations for dev/staging/production overlays
- **Production-Ready**: Security hardening, monitoring, and disaster recovery included

---

## 2. Current Features by Category

### A. HTTP API Handlers & Endpoints

#### Health Checks (Required by Knative)
- **GET /health/live** - Liveness probe
  - No dependencies checked
  - Always returns 200 if process is running
  - Kubernetes restarts pod if fails
  
- **GET /health/ready** - Readiness probe
  - Checks Redis connectivity with PING command
  - Returns 503 if Redis unavailable
  - Kubernetes removes from load balancer if fails

#### Example API Endpoints
- **GET /api/v1/hello** - Demo versioned endpoint
  - Query parameter: `name` (optional)
  - Returns greeting with service version
  - Demonstrates OpenAPI documentation integration

#### CloudEvents/Event Handling
- **POST /** - Root endpoint for Knative event sink
  - Accepts CloudEvents format (from Kafka, HTTP sources)
  - Supports structured event data deserialization
  - Automatic trace span creation with event ID/type

#### Storage Endpoints (Optional - S3 Feature)
- **POST /api/v1/storage/example** - S3 operation demo
  - Write/read/verify/delete cycle
  - Demonstrates OpenDAL usage
  - Returns operation success and data integrity verification

#### OpenAPI/Swagger
- **GET /swagger-ui** - Interactive API documentation
- **GET /api-docs/openapi.json** - OpenAPI spec

#### Metrics
- **GET /metrics** - Prometheus metrics endpoint
  - HTTP request duration (histograms)
  - Request counts (counters)
  - Resource usage (CPU, memory)

### B. Storage Backends

#### Conditional Feature: S3-Compatible Storage (Optional)
- **Technology**: OpenDAL (unified storage abstraction layer)
- **Supported Backends**:
  - MinIO (development/on-premises)
  - AWS S3 (production)
  - Google Cloud Storage
  - Any S3-compatible service
  
- **Capabilities**:
  - `write()` - Upload/overwrite objects
  - `read()` - Download objects
  - `list()` - List objects with prefix filtering
  - `stat()` - Get object metadata
  - `delete()` - Delete objects
  - `rename()` - Move objects
  
- **Features**:
  - Built-in retry logic with exponential backoff
  - Connection pooling
  - Automatic credentials from AWS environment variables
  
- **Configuration**:
  - Endpoint: configurable via `APP__S3__ENDPOINT`
  - Bucket: configurable via `APP__S3__BUCKET`
  - Region: configurable via `APP__S3__REGION`
  - Credentials: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY env vars

#### Non-S3 Storage
- **Redis** (REQUIRED): In-memory cache/session store
  - Multiplexed async connection (no pooling needed)
  - Used for caching, sessions, temporary data
  - PING health check included

### C. Database Features

#### PostgreSQL Integration (via CloudNativePG Operator)
- **Operator**: CloudNativePG 1.28.0
- **Deployment Model**: Kubernetes CRD-based (not ORM-integrated in app)

- **High Availability**:
  - Multi-instance clusters with automatic failover
  - Quorum-based replication in production
  - Asynchronous replication in dev/staging

- **Backup & Disaster Recovery**:
  - Automated scheduled backups to S3-compatible storage
  - Barman Cloud Plugin integration
  - Point-in-Time Recovery (PITR) within retention window
  - Backup retention policies (7-30 days by environment)
  - Compression options (gzip, zstd)
  
- **Monitoring & Alerting**:
  - Prometheus metrics for backup status, replication lag
  - Alert rules for backup failures
  - Health check endpoints for cluster status
  
- **Environment Configurations**:
  - **Dev**: 1 instance, async replication, 7-day retention, MinIO backups, 20Gi storage
  - **Staging**: 2 instances, async replication, 14-day retention, S3 backups, 100Gi storage
  - **Production**: 3 instances, quorum replication, 30-day retention, S3 backups (zstd-10), 200Gi storage

- **Note**: Application doesn't include ORM integration; PostgreSQL is infrastructure managed via Kubernetes manifests

### D. Observability & Monitoring

#### Distributed Tracing
- **Technology**: OpenTelemetry + Jaeger
- **Propagation**: B3 (Zipkin) headers for Knative compatibility
  - X-B3-TraceId, X-B3-SpanId, X-B3-ParentSpanId, X-B3-Sampled
  - Also supports W3C TraceContext standard
- **Span Creation**: Automatic via tower-http middleware + #[instrument] macro
- **Custom Spans**: Support for manual spans and field recording
- **Trace Sampling**: Configurable sampling ratio (development: 100%, production: 1-10%)
- **Transport**: gRPC/OTLP to OpenTelemetry Collector

#### Metrics
- **Technology**: Prometheus-compatible metrics
- **Built-in Metrics**:
  - HTTP request duration (histograms with quantiles)
  - HTTP request counts (counters)
  - Active request gauge
  - Process metrics (CPU, memory, file descriptors)
- **Custom Metrics**: Framework provided for application-specific metrics
- **Export Format**: Prometheus text format + OpenMetrics
- **Endpoint**: GET /metrics

#### Structured Logging
- **Format**: JSON logs with context
- **Levels**: TRACE, DEBUG, INFO, WARN, ERROR
- **Context Fields**:
  - Trace ID and Span ID correlation
  - Request ID from headers
  - Contextual fields via #[instrument] macro
- **Log Aggregation**: Ready for Loki/ELK/centralized logging

#### Observability Stack (Local Development)
- **Jaeger UI**: http://localhost:16686 (distributed tracing)
- **Prometheus**: http://localhost:9090 (metrics)
- **OpenTelemetry Collector**: http://localhost:4317 (ingestion)
- **Optional Loki**: For log aggregation

#### Alerting Capabilities
- Prometheus alert rules examples included
- Integration points for:
  - Slack webhooks
  - PagerDuty
  - Email notifications
- SLO/SLI framework provided

### E. Deployment & Infrastructure Features

#### Knative Serving Integration
- **Port**: Always 8080 (Knative requirement)
- **Auto-Scaling**:
  - Min scale: 1 (or 0 for true serverless)
  - Max scale: 100 (configurable)
  - Target utilization: 70% CPU (configurable)
  - Scale-to-zero after 5+ minutes idle
  
- **Health Checks**:
  - Liveness probe: /health/live
  - Readiness probe: /health/ready
  - Knative removes pod from load balancer if readiness fails
  
- **Graceful Shutdown**:
  - SIGTERM handler with 30-second grace period
  - Closes connections cleanly
  - Finishes in-flight requests before shutdown
  - OpenTelemetry provider shutdown

#### FluxCD GitOps
- **Source Control**: Git as single source of truth
- **Automated Deployment**: Flux polls Git every minute
- **Infrastructure as Code**: Kustomize + YAML manifests
- **Features**:
  - Automatic image updates with tag policies
  - Multi-environment support (dev/staging/prod overlays)
  - Namespace management
  - RBAC configuration

#### Container Deployment
- **Docker Support**:
  - Multi-stage Dockerfile with cargo-chef (layer caching)
  - musl target for Alpine Linux (smaller image)
  - Optimized release builds (LTO, single codegen unit, stripped)
  - Non-root user execution
  - Read-only root filesystem support

#### Environment Configuration
- **Three-Tier Hierarchy**:
  1. Environment variables (highest priority): `APP__*` prefix
  2. Environment-specific files: `config/{env}.toml`
  3. Default hardcoded values (lowest priority)

- **Configuration Files**:
  - `config/default.toml` - Base defaults
  - `config/development.toml` - Dev overrides
  - `config/production.toml` - Prod overrides

- **Configurable Parameters**:
  - Server: host, port
  - Redis: connection URL
  - Telemetry: OTLP endpoint, service name, log level
  - S3: endpoint, bucket, region (if S3 feature enabled)

#### Kubernetes Manifest Organization
- **Base Configuration**: `deploy/base/`
  - Knative Service
  - Kafka Source (event streaming)
  - Dead Letter Queue handler
  - PostgreSQL manifests
  - Storage secrets
  
- **Environment Overlays**: `deploy/overlays/{dev,staging,prod}/`
  - Environment-specific patches
  - Resource limits/requests
  - Replica counts
  - Infrastructure configuration (Kafka servers, databases)

#### FluxCD Integration
- **Git Repository Configuration**: `deploy/flux/git-repository.yaml`
- **Kustomization Controllers**: Auto-apply manifests
- **Image Update Automation**: Optional automated image updates
- **Image Policy/Repository**: Tag-based image selection

### F. Event Streaming & Kafka

#### Knative Eventing Integration
- **Technology**: Knative Eventing + Kafka Broker/Source
- **CloudEvents Support**:
  - Automatic conversion from Kafka messages to CloudEvents
  - Required fields: specversion, type, source, id, data
  - Optional fields: time, datacontenttype, subject, etc.

#### KafkaSource Features
- **Topic Consumption**: One KafkaSource per topic (recommended pattern)
- **Consumer Groups**: Separate consumer group per source
- **Initial Offset**: Configurable (earliest, latest)
- **Consumer Scaling**: Match to topic partitions for optimal throughput
- **Failure Handling**:
  - Automatic retries (configurable count, exponential backoff)
  - Dead Letter Queue (DLQ) for failed events
  - DLQ handler included (event_display for dev, customizable for prod)

#### Event Type Routing
- **Root Endpoint**: POST / (receives CloudEvents)
- **Type-Based Routing**: Pattern provided for routing by `ce-type` header
- **Multiple Topics**: Create additional KafkaSource CRDs
- **Idempotency**: Framework for using event.id() as idempotency key

#### Kafka Configuration (Local Development)
- **Deployment**: Kafka in `kafka` namespace via Kind
- **Bootstrap Servers**: `kafka.kafka.svc.cluster.local:9092`
- **Topic Configuration**: 3 partitions, 1 replication (dev only)
- **Consumer Configuration**: 3 consumers per source (matches partitions)

#### Production Kafka Support
- **External Kafka**: Bootstrap server override via overlays
- **Security**:
  - TLS encryption support
  - SASL authentication (PLAIN, SCRAM-SHA-256, SCRAM-SHA-512)
  - Certificate management via Kubernetes secrets
- **Configuration Patterns**: Staging/production overlays provided

### G. Testing Infrastructure

#### Test Types Supported
- **Unit Tests**: Inline in source files (#[test], #[tokio::test])
- **Integration Tests**: Full handler testing with Redis/S3 (tests/ directory)
- **E2E Tests**: Kind cluster + full Kubernetes deployment

#### Testing Tools
- **axum-test**: Handler testing
- **tokio-test**: Async runtime testing
- **sqlx**: PostgreSQL integration testing
- **figment**: Configuration testing

#### Testing Utilities
- **Common Test Functions**: `tests/common/mod.rs.liquid`
- **E2E Test Scripts**: `tests/e2e/scripts/` (Kind setup, Knative install, etc.)
- **Test Plan Documentation**: `tests/TEST_PLAN.md`

#### Local Development Testing
- **make dev-up**: Full environment (Kind, Knative, Redis, MinIO, Kafka, PostgreSQL, Observability)
- **make dev-logs**: Follow service logs
- **cargo test**: Run all tests
- **cargo watch -x test**: Auto-rerun on changes

---

## 3. Current Limitations (What It Does NOT Do)

### Application-Level Features NOT Included
- **No Built-in Database ORM**: PostgreSQL is managed infrastructure, not application-integrated
  - Users must write custom database connection code
  - No sqlx/tokio-postgres integration in main app
  - Database initialization/migrations not automated
  
- **No Authentication/Authorization**: 
  - No JWT validation
  - No OAuth2 integration
  - No RBAC framework
  - Basic CORS/request validation only
  
- **No Data Persistence Helpers**:
  - No session management framework
  - No caching layer abstraction (Redis only)
  - No database connection pooling setup
  
- **No Message Queue Integration**:
  - Kafka is one-way source only (events consumed, not published)
  - No built-in event publishing to Kafka
  - No inter-service message bus
  
- **No Business Logic**:
  - Only example handlers provided
  - No domain models or entity types
  - No validation frameworks beyond request parsing

### Deployment Limitations
- **Kubernetes-Only**: Cannot run outside Kubernetes
- **Requires Knative**: Depends on Knative Serving for scaling/management
- **Fixed Port (8080)**: Cannot change (Knative requirement)

### Observability Limitations
- **Optional OTLP**: Traces only logged if OTLP endpoint not configured
- **No Built-in Alerting**: Alert rules provided as examples, not deployed by default
- **No Metrics Storage**: Prometheus not included in production recommendations

### Event Processing Limitations
- **Kafka Only**: Only Kafka event source included (HTTP sources not implemented)
- **Single Event Handler**: One root endpoint handler (users must route internally)
- **No Event Schema Registry**: No schema validation framework
- **No Event Publishing**: Service consumes events but doesn't publish

### Storage Limitations
- **S3-Only Abstraction**: No local filesystem storage
- **Conditional Feature**: S3 storage requires feature flag during generation
- **No Data Access Patterns**: No abstraction for common patterns (CRUD, pagination)

### Testing Limitations
- **E2E Tests Manual**: No automated E2E test generation
- **Limited Test Fixtures**: Basic fixtures provided, complex scenarios require custom code
- **No Load Testing**: No load test examples or frameworks

### Kubernetes-Specific Limitations
- **FluxCD Required**: GitOps pattern baked in, not optional
- **No Helm Charts**: Kustomize patches only (some prefer Helm)
- **No Multi-Cluster**: Single cluster deployment patterns

---

## 4. Technology Stack Summary

### Language & Runtime
- **Language**: Rust 1.92+ (can specify via rust-toolchain.toml)
- **Edition**: Rust 2024
- **Async Runtime**: Tokio 1.41+ (full features)
- **Build Tools**: cargo-chef for layer caching

### Web Framework
- **Framework**: Axum 0.8 (lightweight, composable)
- **HTTP Server**: Hyper (via Axum)
- **Routing**: Tower-compatible middleware
- **HTTP Tracing**: tower-http 0.6

### Serialization & Data
- **JSON**: serde_json 1.0, serde 1.0
- **CloudEvents**: Custom vendored crate (axum-cloudevents)
- **Configuration**: figment 0.10 (TOML + env vars)

### Observability Stack
- **Tracing Framework**: tracing 0.1, tracing-subscriber 0.3
- **OpenTelemetry**: opentelemetry 0.31, opentelemetry_sdk 0.31
- **Trace Export**: opentelemetry-otlp 0.31 (gRPC/Tonic)
- **B3 Propagation**: opentelemetry-zipkin 0.31
- **Metrics**: metrics 0.21, metrics-exporter-prometheus 0.13

### Storage & Caching
- **Redis**: redis 0.24 (async, multiplexed connection)
- **Object Storage**: opendal 0.55 (S3 services feature, optional)
- **Data Formats**: chrono 0.4, uuid 1.0 (optional, for S3 feature)

### Error Handling
- **Error Types**: thiserror 1.0
- **Result Type**: anyhow 1.0

### Documentation & API
- **OpenAPI**: utoipa 5, utoipa-swagger-ui 9
- **Automatic Doc Generation**: From handler attributes

### Kubernetes Integration
- **Serving Platform**: Knative Serving 1.12+
- **Event Source**: Knative Eventing with Kafka Source
- **Database**: CloudNativePG Operator 1.28.0
- **GitOps**: FluxCD 2.0+

### Container & Deployment
- **Container Runtime**: Docker/OCI (Alpine for prod via musl target)
- **Image Optimization**: Multi-stage build, LTO, stripped binaries
- **Infrastructure as Code**: YAML manifests, Kustomize patches
- **Secrets Management**: Kubernetes Secrets, SOPS encrypted values

### Development & Testing
- **Testing**: axum-test 17, tokio-test 0.4
- **Database Testing**: sqlx 0.8 (PostgreSQL)
- **Local Kubernetes**: Kind (via make dev-up)
- **Container Orchestration**: Docker Compose (implicit via Kind scripts)

### Optional/Conditional Dependencies
- **S3 Feature**:
  - opendal 0.55 (services-s3 feature)
  - chrono 0.4
  - uuid 1.0

### Development Environment
- **Package Manager**: cargo
- **Build System**: Makefile (convenience targets)
- **Configuration Management**: Figment (hierarchical config)
- **Logging Framework**: tracing (structured logs)

### Databases & Infrastructure
- **Database**: PostgreSQL 14+ (managed via CloudNativePG)
- **Message Queue**: Apache Kafka (optional, event-driven)
- **In-Memory Store**: Redis (required for caching)
- **Object Storage**: MinIO (dev), AWS S3 (production)
- **Tracing Backend**: Jaeger
- **Metrics Backend**: Prometheus
- **Log Aggregation**: Loki/ELK (optional)

### Deployment Patterns
- **Container Orchestration**: Kubernetes 1.24+
- **Serverless Platform**: Knative Serving
- **GitOps Tool**: FluxCD 2.0+
- **Configuration Format**: YAML + Kustomize
- **Infrastructure Code**: Kubernetes manifests (CRDs)

---

## Summary Table: Features At a Glance

| Category | Feature | Status | Notes |
|----------|---------|--------|-------|
| **HTTP API** | REST endpoints | ✅ Built-in | Example hello + storage endpoints |
| | Versioned API routes | ✅ Built-in | /api/v1/hello pattern |
| | OpenAPI/Swagger docs | ✅ Built-in | Auto-generated from handlers |
| | Health checks | ✅ Required | /health/live and /health/ready |
| | Metrics endpoint | ✅ Built-in | Prometheus format |
| **Storage** | S3-compatible (optional) | ✅ Conditional | OpenDAL abstraction |
| | Redis caching | ✅ Required | Multiplexed async connection |
| | PostgreSQL | ✅ Operators | Via CloudNativePG CRDs |
| **Events** | CloudEvents support | ✅ Built-in | Knative-compatible |
| | Kafka event source | ✅ Built-in | Knative KafkaSource |
| | Kafka publishing | ❌ Not included | Consume-only pattern |
| | Dead Letter Queue | ✅ Built-in | Included in manifests |
| **Observability** | Distributed tracing | ✅ Built-in | Jaeger via OpenTelemetry |
| | Metrics collection | ✅ Built-in | Prometheus |
| | Structured logging | ✅ Built-in | JSON logs with trace IDs |
| | Alerting rules | ⚠️ Examples | Patterns provided, not deployed |
| **Deployment** | Knative serving | ✅ Required | Auto-scaling, revisions |
| | FluxCD GitOps | ✅ Built-in | Git-driven deployment |
| | Multi-environment overlays | ✅ Built-in | Dev/staging/prod |
| | Kustomize patches | ✅ Built-in | Base + overlays pattern |
| | Docker support | ✅ Built-in | Multi-stage, optimized |
| **Infrastructure** | Kind support | ✅ Built-in | make dev-up |
| | Kafka cluster | ✅ Local only | Included in Kind setup |
| | PostgreSQL HA | ✅ Operators | CloudNativePG 1.28.0 |
| | Backup/PITR | ✅ Built-in | Barman Cloud + S3 |
| | Monitoring/alerting | ✅ Operators | Prometheus rules included |
| **Testing** | Unit tests | ✅ Built-in | #[test] support |
| | Integration tests | ✅ Built-in | With Redis/S3 |
| | E2E tests | ✅ Scripts | Kind + Kustomize scripts |
| **Authentication** | JWT validation | ❌ Not included | Must implement |
| | OAuth2 | ❌ Not included | Must implement |
| | RBAC framework | ❌ Not included | Must implement |
| **Data Access** | ORM integration | ❌ Not included | Use sqlx or diesel |
| | Database migrations | ❌ Not included | Use sqlx-cli or custom |
| | Session management | ❌ Not included | Custom Redis-based |

---

## Conclusion

This is a **well-engineered microservice template** optimized for Kubernetes serverless deployments. It excels at:

1. **Observability** - Enterprise-grade tracing, metrics, and logging
2. **Cloud-Native Deployment** - Knative + FluxCD GitOps patterns
3. **Infrastructure as Code** - Complete Kubernetes manifests included
4. **Event-Driven Architecture** - Kafka integration with Knative Eventing
5. **Production Database** - CloudNativePG with HA, backups, PITR

However, it's **intentionally minimal on business logic** - it provides the foundation and examples, expecting developers to add domain-specific code (authentication, database integration, specific event handlers, etc.).

Best suited for teams wanting to:
- Build Kubernetes-native microservices
- Implement comprehensive observability from day one
- Use GitOps for infrastructure management
- Deploy serverless workloads with Knative
- Integrate event-driven patterns with Kafka

