# Template Configuration Guide

This is a `cargo-generate` template. It supports conditional features that are applied during project generation.

## Features

This template includes:

- **Rust Axum Web Framework**: High-performance async web service
- **Knative Serverless**: Cloud-native serverless deployment
- **Kafka Event Streaming**: Event-driven architectures
- **CloudNativePG Database**: Production-grade PostgreSQL with HA, backups, and PITR
- **FluxCD GitOps**: Infrastructure as code with Kubernetes
- **OpenTelemetry Observability**: Distributed tracing and metrics

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

## Template Structure

All files with `.liquid` extension are template files using Shopify Liquid syntax. They are automatically renamed (`.liquid` removed) during generation.

### Liquid Variables

The template supports these variables:

| Variable | Source | Example |
|----------|--------|---------|
| project_name | User prompt | my-awesome-service |
| crate_name | Auto-derived | my_awesome_service |
| if features contains "s3" | User prompt | true or false |
| enable_image_updates | User prompt | true or false |
| target_namespace | User prompt | default |
| github_org | User prompt | enchantednatures |
| github_repo | User prompt | rust-knative-flux-template |
| default_branch | User prompt | main |

## Generation Flow

When you run:

```bash
cargo generate --git https://github.com/your-org/rust-knative-flux-template
```

Cargo-generate:

1. **Prompts for values**:
   - `project_name`: Your project name
   - `if features contains "s3"`: Whether to include S3 support
   - `enable_image_updates`: Enable automated image updates with FluxCD
   - `target_namespace`: Kubernetes namespace for deployment
   - `github_org`: GitHub organization or username
   - `github_repo`: GitHub repository name
   - `default_branch`: Git branch for Flux to monitor

2. **Processes template files**:
   - Evaluates all `*.liquid` files with your values
   - Renames files (removes `.liquid` extension)
   - Removes conditionally excluded content

3. **Non-liquid files** are copied as-is

## References

- [cargo-generate docs](https://cargo-generate.github.io/cargo-generate/)
- [Liquid template language](https://shopify.github.io/liquid/)
- [CloudNativePG Documentation](https://cloudnative-pg.io/)
- [Knative Documentation](https://knative.dev/)
- [FluxCD Documentation](https://fluxcd.io/)

