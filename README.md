# Rust Knative Flux Template

A production-ready `cargo-generate` template for building Rust microservices on Knative with GitOps deployment via FluxCD.

## Features

This template provides a complete, batteries-included foundation for cloud-native Rust services:

- **🦀 Rust Axum Web Framework**: High-performance async web service with CloudEvents support
- **🚀 Knative Serverless**: Auto-scaling, scale-to-zero serverless deployment
- **📨 Kafka Integration**: Optional event-driven architecture (consuming via KafkaSource + publishing from handlers)
- **🗄️ CloudNativePG Database**: Production-grade PostgreSQL with HA, automated backups, and PITR
- **📦 S3-Compatible Storage**: Optional MinIO/AWS S3 integration via OpenDAL
- **🔄 FluxCD GitOps**: Declarative infrastructure as code with automated deployments
- **🔍 OpenTelemetry Observability**: Distributed tracing (Jaeger), metrics (Prometheus), and structured logging
- **🏗️ Multi-Environment Ready**: Dev, staging, and production overlay configurations
- **🧪 Fully Tested**: Integration tests, health checks, and CI/CD pipelines included
- **📝 Type-Safe**: Vendored `axum-cloudevents` crate for CloudEvents 1.0 compliance

## PostgreSQL Support

This template includes comprehensive PostgreSQL database support with:

- **High Availability**: Multi-instance clusters with automatic failover
- **Automated Backups**: Scheduled backups to S3/MinIO with retention policies
- **Point-in-Time Recovery**: Restore to any moment within retention window
- **Monitoring & Alerting**: Prometheus metrics and alert rules for backup/replication
- **Disaster Recovery**: Complete procedures and testing

### PostgreSQL Quick Start

```bash
# Deploy PostgreSQL cluster with HA
make dev-up

# Connect to database
./scripts/dev/port-forward-postgres.sh
psql postgresql://app:PASSWORD@localhost:5432/app

# Create backup
./scripts/dev/create-backup.sh

# Restore from backup
./scripts/dev/restore-from-backup.sh
```

### PostgreSQL Documentation

- [Operations Guide](docs/POSTGRES.md) - Deployment, configuration, scaling
- [Backup & Restore Guide](docs/POSTGRES_BACKUP_RESTORE.md) - Backup procedures, PITR, disaster recovery
- [Monitoring Guide](docs/POSTGRES_MONITORING.md) - Metrics, alerts, Grafana setup

## Quick Start

Generate a new project from this template:

```bash
# Recommended: Use --allow-commands to automatically format and lint
cargo generate --git https://github.com/enchantednatures/rust-knative-flux-template --allow-commands
```

The template will prompt you for:
- **Project name**: Your microservice name
- **Features**: Select from S3, PostgreSQL, Kafka publishing
- **Event sources**: Select Kafka event source for consuming
- **Image updates**: Enable/disable FluxCD automated image updates
- **Kubernetes namespace**: Target namespace for deployment
- **GitHub org/repo**: For GitOps configuration
- **Git branch**: Branch for Flux to monitor

### What You Get

After generation, you'll have:
- ✅ A working Rust microservice with health checks
- ✅ Knative Service manifest with auto-scaling
- ✅ FluxCD GitRepository and Kustomization for GitOps
- ✅ Multi-environment overlays (dev, staging, prod)
- ✅ Docker multi-stage build with cargo-chef caching
- ✅ OpenTelemetry instrumentation (B3 propagation for Knative)
- ✅ Integration tests and CI/CD workflows
- ✅ Comprehensive documentation

## Template Structure

All files with `.liquid` extension are template files using Shopify Liquid syntax. They are automatically renamed (`.liquid` removed) during generation.

### Template Variables

| Variable | Type | Description | Example |
|----------|------|-------------|---------|
| `project_name` | String | Your project name (kebab-case) | my-awesome-service |
| `crate_name` | String | Auto-derived Rust crate name (snake_case) | my_awesome_service |
| `features` | Array | Optional features (s3, postgres, kafka) | ["s3", "kafka"] |
| `event_sources` | Array | Event sources (kafka for KafkaSource) | ["kafka"] |
| `enable_image_updates` | Boolean | Enable FluxCD image updates | true |
| `target_namespace` | String | Kubernetes namespace | default |
| `github_org` | String | GitHub organization/username | enchantednatures |
| `github_repo` | String | GitHub repository name | my-service |
| `default_branch` | String | Git branch for Flux | main |
| `base_min_scale` | String | Base minimum replicas | "1" |
| `base_cpu_request` | String | Base CPU request | "100m" |
| `base_memory_request` | String | Base memory request | "64Mi" |

**Note**: Scaling parameters (min/max scale, CPU/memory) have sensible defaults and can be customized post-generation in `deploy/base/knative-service.yaml`.

## Optional Features

### S3-Compatible Storage (`features = ["s3"]`)

When enabled, adds:
- OpenDAL integration for MinIO/AWS S3
- Storage handlers for upload/download/list/delete operations
- S3 configuration in environment and TOML files
- Integration tests with MinIO
- Terraform module for bucket management

### PostgreSQL Database (`features = ["postgres"]`)

When enabled, adds:
- CloudNativePG cluster configuration with HA
- Automated backup to S3/MinIO with retention policies
- Point-in-Time Recovery (PITR) capabilities
- Prometheus metrics and alert rules
- Deployment scripts and monitoring dashboards
- Comprehensive operations documentation

### Kafka Event Publishing (`features = ["kafka"]`)

When enabled, adds:
- Kafka publisher integrated into AppState
- Non-blocking event publishing from HTTP handlers
- CloudEvents 1.0 format via vendored `axum-cloudevents` crate
- Prometheus metrics (publish count, latency, errors)
- Configuration for broker, topic, compression, batching
- Example handlers demonstrating publish patterns

### Kafka Event Source (`event_sources = ["kafka"]`)

When enabled, adds:
- Knative KafkaSource for consuming Kafka events
- Dead Letter Queue (DLQ) handler for failed events
- Topic-per-source pattern for independent scaling
- CloudEvents handlers for processing incoming events
- Multi-environment configuration (dev with local Kafka, staging/prod with external)

## Vendored Dependencies

This template includes local crates in `crates/`:

### `axum-cloudevents`

A custom CloudEvents integration for Axum providing:
- Type-safe CloudEvent extractor for HTTP requests
- Support for structured and binary content modes
- HTTP header mapping for CloudEvents metadata
- Full CloudEvents 1.0 specification compliance

**Why vendored?**
- Custom functionality tailored for Knative/serverless use cases
- No dependency on unmaintained or incompatible external crates
- Full control over CloudEvents implementation
- Easy to customize for your specific needs

The crate is referenced as a path dependency and can be modified directly in `crates/axum-cloudevents/`.

## Generation Flow

When you run `cargo generate`:

> **💡 Important**: The `--allow-commands` flag is **highly recommended**. It allows the template to automatically run `cargo clippy --fix` and `cargo fmt` on the generated code without prompting.
> 
> **Without this flag**, you'll be prompted to approve each command. In CI/automated environments, this flag is **required**.

**Process:**

1. **Prompts for configuration** (or uses template-values.toml file)
2. **Evaluates template files**: All `*.liquid` files are processed with your values
3. **Conditional exclusion**: Files/sections not matching selected features are removed
4. **Renames files**: Removes `.liquid` extension
5. **Runs post-generation hooks**:
   - Formats code with `cargo fmt`
   - Fixes linting issues with `cargo clippy --fix`
   - Runs `cargo check` to verify compilation

### Usage Options

**Automatic mode (recommended):**
```bash
cargo generate --git https://github.com/enchantednatures/rust-knative-flux-template --allow-commands
```

**With template values file:**
```bash
cargo generate --git <url> --template-values-file values.toml --allow-commands
```

**Interactive mode:**
```bash
cargo generate --git <url>
```
You'll be prompted to approve each post-generation command.

## Architecture

### Key Design Decisions

**Multi-Stage Docker Build with cargo-chef**
- Caches Rust dependencies separately from source code
- Includes vendored `crates/` directory before dependency compilation
- Produces minimal Alpine-based runtime image (~50MB)

**B3 Propagation for Knative**
- Uses OpenTelemetry Zipkin exporter for B3 header propagation
- Required for Knative distributed tracing
- Integrates with Istio/Linkerd service mesh

**Non-Blocking Kafka Publishing**
- Uses `tokio::spawn` for async event publishing
- HTTP responses return immediately (200 OK)
- Publisher errors logged but don't fail requests
- Prometheus metrics track publish success/failure rates

**Environment-Specific Overlays**
- **Dev**: Scale-to-zero, local MinIO, verbose logging
- **Staging**: Min 1 replica, external services, info logging
- **Production**: Min 2 replicas, HA PostgreSQL, warn logging

### Project Layout

```
rust-knative-flux-template/
├── src/                      # Rust source code
├── crates/                   # Vendored local dependencies
│   └── axum-cloudevents/     # CloudEvents extractor
├── config/                   # TOML configuration files
├── deploy/                   # Kubernetes manifests
│   ├── base/                 # Base Knative Service
│   ├── overlays/             # Environment-specific patches
│   └── flux/                 # FluxCD GitOps resources
├── tests/                    # Integration tests
├── scripts/                  # Development scripts
├── terraform/                # Infrastructure as code
├── Dockerfile.liquid         # Multi-stage build template
├── cargo-generate.toml       # Template configuration
└── README.md.liquid          # Generated project README
```

## Continuous Integration

This template includes GitHub Actions workflows for:

**E2E Tests** (`.github/workflows/template-e2e-test.yaml`)
- Generates projects with different feature combinations
- Builds Docker images
- Deploys to Kind cluster with Knative
- Runs end-to-end health check tests
- Validates FluxCD reconciliation

**Template Generation & Validation** (`.github/workflows/template-generate-and-validate.yaml`)
- Tests all feature combinations (8 matrix scenarios)
- Validates generated code compiles
- Runs clippy and formatting checks
- Ensures no build errors

## Troubleshooting

### "Error: missing prompt question for base_min_scale"

This occurs when using the template without providing all scaling parameters. Solution:
- Use `--allow-commands` flag
- Or provide template-values.toml with all required values
- Scaling parameters have defaults and won't prompt in latest version

### "Error: IO error: not a terminal"

Occurs in CI/non-interactive environments when template tries to prompt. Solution:
- Always use `--allow-commands` in CI
- Or provide complete template-values.toml file

### Docker Build Fails: "cannot find crates/axum-cloudevents"

The Dockerfile must copy `crates/` before running `cargo chef cook`. Fixed in latest version:
```dockerfile
COPY crates ./crates
RUN cargo chef cook --release --target x86_64-unknown-linux-musl
```

### Knative Validation Error: "quantities must match the regular expression"

Resource quantities (CPU/memory) were empty. Fixed in latest version - all scaling parameters have defaults.

## Contributing

Contributions welcome! Areas for improvement:
- Additional database providers (MySQL, MongoDB)
- More event sources (Google Pub/Sub, AWS SQS)
- Enhanced observability (Grafana dashboards, alert rules)
- Additional deployment targets (AWS Lambda, Google Cloud Run)

## References

- [cargo-generate Documentation](https://cargo-generate.github.io/cargo-generate/)
- [Liquid Template Language](https://shopify.github.io/liquid/)
- [Knative Documentation](https://knative.dev/)
- [FluxCD Documentation](https://fluxcd.io/)
- [CloudNativePG Documentation](https://cloudnative-pg.io/)
- [OpenTelemetry Rust](https://github.com/open-telemetry/opentelemetry-rust)
- [CloudEvents Specification](https://cloudevents.io/)

## License

MIT License - See LICENSE file

## Support

For issues or questions:
1. Check [GitHub Issues](https://github.com/enchantednatures/rust-knative-flux-template/issues)
2. Review documentation in `docs/` directory
3. Check CI logs for E2E test examples
4. Open a new issue with template version and error details

