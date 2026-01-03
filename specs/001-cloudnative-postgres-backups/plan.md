# Implementation Plan: CloudNative PostgreSQL with Automated Backups

**Branch**: `001-cloudnative-postgres-backups` | **Date**: 2026-01-03 | **Spec**: [spec.md](./spec.md)  
**Input**: Feature specification from `/specs/001-cloudnative-postgres-backups/spec.md`

**Note**: This template is filled in by the `/speckit.plan` command. See `.specify/templates/commands/plan.md` for the execution workflow.

## Summary

This feature adds PostgreSQL database support to the Knative template using CloudNativePG operator for high-availability database clusters with automated backups to S3-compatible object storage via Barman Cloud Plugin (`barman-cloud.cloudnative-pg.io`). The implementation focuses on declarative Kubernetes manifests for GitOps deployment, monitoring integration, and point-in-time recovery capabilities using the modern plugin architecture with `ObjectStore` CRD.

## Technical Context

**Language/Version**: Rust 1.75+ (existing template), YAML manifests for Kubernetes resources  
**Primary Dependencies**: CloudNativePG Operator 1.28.0 (Kubernetes CRDs), Barman Cloud Plugin (barman-cloud.cloudnative-pg.io), FluxCD for GitOps deployment  
**Storage**: PostgreSQL (deployed via CloudNativePG operator), S3-compatible object storage (MinIO for dev, configurable for prod)  
**Testing**: E2E tests using Kind cluster (`tests/e2e/`), integration tests with actual PostgreSQL connections, `kubectl` validation scripts  
**Target Platform**: Kubernetes 1.27+ with Knative Serving, CloudNativePG operator, Barman Cloud Plugin  
**Project Type**: Infrastructure-as-Code (Kubernetes manifests) + optional Rust helper tools for backup management  
**Performance Goals**: <5 min cluster startup, 99% backup success rate, <30 min backup time for 10GB databases, <2 min failover recovery  
**Constraints**: Knative-compatible (no breaking changes to existing services), GitOps workflow via FluxCD, must work in Kind for dev and production K8s clusters, uses plugin architecture (not deprecated built-in barmanObjectStore)  
**Scale/Scope**: Support for multiple PostgreSQL clusters per namespace, configurable replica counts (1-5 recommended), backup retention 7-30 days

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### Mandatory Checks

- [x] **Observability**: CloudNativePG operator provides built-in Prometheus metrics via plugin namespace (`barman_cloud_cloudnative_pg_io_*`); backup operations logged via operator; custom Rust tools (if added) will use `#[instrument]` macro; structured logging with tracing; B3 header propagation maintained for Rust services
- [x] **Testing**: E2E tests for PostgreSQL deployment, backup creation, restore operations in Kind cluster; integration tests for connection and query execution; validation scripts for manifest correctness; `cargo test` for any Rust helper tools
- [x] **Configuration**: PostgreSQL cluster configs follow environment-specific overlays (`deploy/overlays/dev/`, `deploy/overlays/prod/`); object storage credentials via Kubernetes secrets; `APP__` prefix maintained for existing Rust services; no secrets in repository; SOPS + Age encryption for secrets
- [x] **Error Handling**: Backup failures logged by CloudNativePG operator and Barman Cloud Plugin with context; Rust helper tools (if added) will use `thiserror` for custom errors; operator handles retries automatically; validation scripts provide clear error messages
- [x] **Performance**: PostgreSQL cluster startup time target <90 seconds (NFR-006); backup operations use streaming to minimize impact; async operations for Rust tooling; no impact to existing services' <2 second cold start
- [x] **Knative Constraints**: This feature is infrastructure-only (database layer); existing Knative services maintain `/health/live` and `/health/ready` endpoints; SIGTERM handling preserved; B3 propagation unaffected; port 8080 unchanged for application services

### Complexity Tracking

> This feature does not violate constitution principles. It adds infrastructure components (PostgreSQL clusters) that support the existing Rust/Knative application services without modifying their architecture. The plugin-based approach (Barman Cloud Plugin with `ObjectStore` CRD) is used instead of the deprecated built-in `barmanObjectStore` configuration.

## Project Structure

### Documentation (this feature)

```text
specs/001-cloudnative-postgres-backups/
├── plan.md              # This file
├── research.md          # Phase 0 output - CloudNativePG best practices, Barman Cloud Plugin configuration patterns
├── data-model.md        # Phase 1 output - PostgreSQL cluster entity, backup metadata structures
├── quickstart.md        # Phase 1 output - Quick deployment guide for operators
├── contracts/           # Phase 1 output - Kubernetes manifest schemas (Cluster, Backup, ScheduledBackup CRDs, ObjectStore CRD)
└── checklists/          # Validation checklists
    └── requirements.md  # Spec quality validation (already completed)
```

### Source Code (repository root)

```text
# Infrastructure manifests (primary deliverable)
deploy/
├── base/
│   ├── postgres-cluster.yaml       # CloudNativePG Cluster CRD base manifest
│   ├── postgres-backup.yaml        # ScheduledBackup CRD definitions (uses plugin)
│   ├── postgres-objectstore.yaml   # ObjectStore CRD for Barman Cloud Plugin
│   ├── postgres-pooler.yaml        # PgBouncer connection pooler (optional)
│   ├── postgres-podmonitor.yaml    # Prometheus metrics collection
│   ├── postgres-alerts.yaml        # PrometheusRule for backup alerts
│   ├── object-storage-secret.yaml.example  # S3 credentials template
│   └── kustomization.yaml          # Updated to include PostgreSQL resources
├── overlays/
│   ├── dev/
│   │   ├── postgres-cluster-patch.yaml    # Dev-specific: 1 replica, smaller resources
│   │   ├── postgres-objectstore-patch.yaml # Dev: MinIO configuration, gzip compression
│   │   ├── minio-setup.yaml               # MinIO for local object storage
│   │   └── kustomization.yaml             # Dev overlay
│   ├── staging/
│   │   ├── postgres-cluster-patch.yaml    # Staging: 2 replicas, moderate resources
│   │   ├── postgres-objectstore-patch.yaml # Staging: S3 configuration, zstd compression
│   │   └── kustomization.yaml
│   └── prod/
│       ├── postgres-cluster-patch.yaml    # Prod: 3 replicas, production resources
│       ├── postgres-objectstore-patch.yaml # Prod: S3, zstd compression, SSE-S3 encryption
│       ├── backup-schedule-patch.yaml     # More frequent backups for prod
│       └── kustomization.yaml
└── flux/
    ├── postgres-gitrepository.yaml        # GitRepository source for PostgreSQL manifests
    └── postgres-kustomization.yaml        # FluxCD kustomization for PostgreSQL resources (with SOPS decryption)

# Infrastructure setup
deploy/infrastructure/
└── cloudnative-pg/
    ├── operator/
    │   └── kustomization.yaml             # CloudNativePG operator 1.28.0
    └── plugin/
        └── kustomization.yaml             # Barman Cloud Plugin (raw manifests)

# Development infrastructure
scripts/
├── dev/
│   ├── deploy-postgres.sh          # Deploy PostgreSQL to Kind cluster
│   ├── create-backup.sh            # Trigger manual backup
│   ├── restore-from-backup.sh      # Restore to new cluster
│   ├── check-backup-status.sh      # Query backup metrics
│   └── port-forward-postgres.sh    # Local access to PostgreSQL
└── validate-postgres-manifests.sh  # CI validation for manifests

# E2E tests
tests/
├── e2e/
│   ├── fixtures/
│   │   └── postgres/
│   │       ├── test-cluster.yaml           # Minimal test cluster
│   │       ├── test-objectstore.yaml       # ObjectStore CRD for tests
│   │       ├── test-backup-config.yaml     # Test backup schedule
│   │       └── test-data.sql               # Sample data for backup/restore validation
│   └── scripts/
│       ├── 07-deploy-postgres.sh           # Install CloudNativePG operator and plugin
│       ├── 08-test-postgres-deployment.sh  # Verify cluster creation
│       ├── 09-test-backup-restore.sh       # Backup and restore workflow
│       ├── 10-test-failover.sh             # Primary failure and replica promotion
│       └── 11-test-monitoring.sh           # Metrics and alerts validation
└── integration/
    └── postgres_connection_test.rs         # Rust test: connect and query PostgreSQL

# Optional: Rust helper tools (if CLI tooling needed)
crates/
└── postgres-backup-cli/                    # Optional CLI for backup management
    ├── src/
    │   ├── main.rs                         # CLI entry point
    │   ├── commands/
    │   │   ├── list_backups.rs             # List available backups
    │   │   ├── trigger_backup.rs           # Trigger manual backup
    │   │   └── restore.rs                  # Initiate restore operation
    │   └── k8s_client.rs                   # Kubernetes API client wrapper
    ├── Cargo.toml
    └── README.md

# Documentation
docs/
├── POSTGRES.md                             # PostgreSQL deployment and operations guide
├── POSTGRES_BACKUP_RESTORE.md              # Backup and restore procedures
└── POSTGRES_MONITORING.md                  # Monitoring and alerting setup
```

**Structure Decision**: This feature primarily adds Kubernetes manifests under `deploy/` with environment-specific overlays, following the existing GitOps pattern. E2E tests extend the existing test suite in `tests/e2e/`. Optional Rust CLI tooling in `crates/` only if management beyond `kubectl` is required. The structure maintains separation of concerns: infrastructure (manifests), testing (E2E scripts), and optional tooling (Rust crates). Uses modern Barman Cloud Plugin architecture with `ObjectStore` CRD instead of deprecated built-in `barmanObjectStore`.

## Phase 0: Research & Unknowns

### Research Output

All research has been completed in `research.md`. Key decisions documented:

#### R1: CloudNativePG Operator Installation and Versioning
**Decision**: CloudNativePG operator version 1.28.0 with raw Kubernetes manifests managed by FluxCD Kustomize. PostgreSQL version 16 (16.11).

#### R2: Barman Cloud Plugin Architecture
**Decision**: Use Barman Cloud Plugin (`barman-cloud.cloudnative-pg.io`) with `ObjectStore` CRD for backup configuration. This is the modern plugin architecture recommended for CloudNativePG 1.26+ (built-in `barmanObjectStore` is deprecated).

#### R3: Barman Cloud Configuration Best Practices
**Decision**: Compression: `gzip` for development (MinIO), `zstd` for production (AWS S3). Encryption: Server-side encryption (SSE-S3). WAL Archiving: Streaming WAL archiving with replication slots (near-zero RPO). Bucket Structure: Single bucket with organized prefix per cluster. Retention: 7-30 days via recovery window policy.

#### R4: PostgreSQL High Availability Configuration
**Decision**: Replica counts: Dev (1), Staging (2), Production (3). Replication mode: Synchronous with quorum for production, asynchronous for dev/staging. Resource templates: Small/Medium/Large defined. PgBouncer: Include for production.

#### R5: Monitoring and Alerting Integration
**Decision**: CloudNativePG native Prometheus exporter on port 9187 via PodMonitor. Plugin-specific metrics namespace: `barman_cloud_cloudnative_pg_io_*` (not legacy `cnpg_collector_*`). PrometheusRule with CloudNativePG-specific alerts. Official Grafana dashboards from CloudNativePG repository.

#### R6: Point-in-Time Recovery (PITR) Implementation
**Decision**: WAL archiving frequency: 5 minutes (PostgreSQL `archive_timeout = 5min`). Restore approach: Always create new cluster using `bootstrap.recovery` with `ObjectStore` reference (not in-place). WAL retention: Match backup retention period (7-30 days). Recovery target: Use `targetTime` with RFC 3339 timestamp format (explicit UTC).

#### R7: Kubernetes Secret Management for Object Storage Credentials
**Decision**: Mozilla SOPS with Age encryption + FluxCD native integration. IRSA/Workload Identity where available (production), static credentials with SOPS for development.

#### R8: E2E Testing Strategy for PostgreSQL Operations
**Decision**: Test data size: <1GB (generated via SQL). Validation approach: Cloud Plugin backup metrics via `ObjectStore` status + restore validation with query comparison. Failover simulation: Pod deletion with `kubectl delete pod`. Parallelization: Sequential execution. Target time: <30 minutes total including all setup.

#### R9: PostgreSQL Version and Extension Support
**Decision**: Default PostgreSQL version: 16 (currently 16.11). Container image: `ghcr.io/cloudnative-pg/postgresql:16-standard-bookworm`. Pre-configured extensions: pg_stat_statements (enabled by default), pgaudit (optional), pgvector (optional).

#### R10: Plugin Installation Method
**Decision**: Raw Kubernetes manifests managed by FluxCD (consistent with operator installation approach, no Helm dependency).

#### R11: ScheduledBackup Plugin Configuration
**Decision**: Explicit plugin reference in ScheduledBackup (`method: plugin`, `pluginConfiguration.name: barman-cloud.cloudnative-pg.io`).

## Phase 1: Design & Contracts

*Prerequisites: `research.md` complete with all NEEDS CLARIFICATION resolved*

### Deliverables

All Phase 1 deliverables have been completed:

#### 1. Data Model (`data-model.md`) ✓

Documented 5 entities with full attributes, relationships, and validation rules:
- PostgreSQL Cluster (with replica configuration, resource allocation, connection endpoints)
- Backup (full base backups only, PITR via WAL replay)
- Backup Configuration (via `ObjectStore` CRD managed by Barman Cloud Plugin)
- Restore Operation (bootstrap configuration for new cluster from backup)
- Object Storage Credentials (SOPS encrypted secrets, IRSA for production)

#### 2. API Contracts (`contracts/`)

**Next**: Generate Kubernetes CRD schemas and example manifests:

- `contracts/cluster-crd-schema.yaml`: CloudNativePG Cluster CRD structure with plugin reference
- `contracts/objectstore-crd-schema.yaml`: Barman Cloud Plugin ObjectStore CRD structure
- `contracts/backup-crd-schema.yaml`: CloudNativePG Backup and ScheduledBackup CRD structure (with plugin method)
- `contracts/example-cluster.yaml`: Example PostgreSQL Cluster manifest with plugin configuration
- `contracts/example-objectstore.yaml`: Example ObjectStore manifest for Barman Cloud Plugin
- `contracts/example-backup-schedule.yaml`: Example ScheduledBackup manifest with explicit plugin reference
- `contracts/example-restore.yaml`: Example restore procedure using bootstrap.recovery

#### 3. Quickstart Guide (`quickstart.md`)

**Next**: Provide step-by-step instructions for operators:

**Section 1: Prerequisites**
- Kubernetes cluster with CloudNativePG operator and Barman Cloud Plugin installed
- Object storage (MinIO for dev, S3 for prod) accessible
- `kubectl` and `flux` CLI installed

**Section 2: Deploy a PostgreSQL Cluster (5 minutes)**
1. Create ObjectStore CRD for Barman Cloud Plugin
2. Create object storage secret
3. Apply cluster manifest (with plugin reference in `.spec.plugins[]`)
4. Verify cluster health
5. Connect to PostgreSQL

**Section 3: Configure Automated Backups (2 minutes)**
1. Configure ScheduledBackup manifest (with `method: plugin`, `pluginConfiguration`)
2. Apply backup schedule
3. Verify backup creation

**Section 4: Restore from Backup (10 minutes)**
1. List available backups
2. Create restore cluster manifest (bootstrap.recovery with ObjectStore reference)
3. Apply restore manifest
4. Verify restored data

**Section 5: Monitoring and Alerts**
1. View PostgreSQL metrics in Prometheus (plugin namespace: `barman_cloud_cloudnative_pg_io_*`)
2. Access Grafana dashboards
3. Configure alert rules

#### 4. Agent Context Update

**Next**: Run the agent context update script to add PostgreSQL-related technologies:

```bash
.specify/scripts/bash/update-agent-context.sh opencode
```

This will update `.specify/memory/agent-context-opencode.md` with:
- CloudNativePG operator and CRD usage patterns
- Barman Cloud Plugin configuration with `ObjectStore` CRD
- Plugin-based backup architecture patterns
- PostgreSQL connection patterns from Rust services
- Backup and restore operational procedures

## Phase 2: Task Breakdown

*Note: Phase 2 is executed by the `/speckit.tasks` command, NOT by `/speckit.plan`*

Task breakdown with dependencies and milestones has been generated in `tasks.md`. Total 80 tasks organized into 7 phases aligned with user stories.

## Success Criteria Validation

Map implementation to spec success criteria:

| Success Criterion | Implementation Validation |
|-------------------|---------------------------|
| SC-001: 5 min cluster deployment | E2E test measures time from `kubectl apply` to ready state; must be <5 min |
| SC-002: 99% backup success rate | Monitor Prometheus metrics `barman_cloud_cloudnative_pg_io_last_failed_backup_timestamp` over 30 days in prod |
| SC-003: 30 min backup for 10GB | E2E test with 10GB test database; measure backup duration; must be <30 min (using 1GB for E2E: ~3-5 min) |
| SC-004: 2 min failover recovery | E2E test deletes primary pod; measure time to new primary elected; must be <2 min |
| SC-005: 15 min restore for 10GB | E2E test restores from 10GB backup; measure time to queryable state; must be <15 min (using 1GB for E2E: ~8-10 min) |
| SC-006: 50% storage cost reduction | Compare PVC costs vs S3 storage costs; document in operational guide |
| SC-007: Zero data loss on failover | E2E test writes data, kills primary, validates data present on new primary |
| SC-008: 5 min failure identification | Alert rule triggers within 5 min of backup failure; validate in alert testing |
| SC-009: 95% incident resolution from logs | Operational runbooks use only logs/metrics; validate during incident response drills |
| SC-010: 24h retention cleanup | Monitor object storage; verify old backups deleted within 24h of expiration |

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| CloudNativePG operator version incompatibility with Kubernetes 1.27+ | Low | High | Research phase validates compatibility; pin operator version in manifests |
| Barman Cloud Plugin migration issues from deprecated built-in approach | Low | High | Use plugin architecture from start (no migration needed); document plugin patterns in contracts/ |
| Backup uploads fail due to insufficient network bandwidth | Medium | High | Monitor backup duration metrics; document bandwidth requirements; configure retry logic |
| MinIO behavior differs from production S3, causing dev/prod inconsistencies | Medium | Medium | Use S3-compatible API exclusively; E2E tests validate against MinIO; document known differences |
| Restore operations take longer than 15 min for 10GB databases | Medium | Medium | Benchmark during E2E tests; adjust success criteria if hardware constraints prevent target |
| Object storage credentials rotation causes backup failures | Low | High | Document rotation procedure with SOPS; implement alerts for authentication failures; test rotation in staging |
| PostgreSQL version upgrade breaks backup compatibility | Low | High | Research backup format compatibility across versions; document upgrade procedures; test upgrades in staging |
| E2E tests exceed CI time limits (>30 min total) | Medium | Low | Use smaller test databases (<1GB); parallelize independent tests; optimize Kind cluster startup |
| FluxCD reconciliation conflicts with manual `kubectl` operations | Low | Medium | Document GitOps-only workflow; disable manual changes via RBAC; alert on drift detection |
| Plugin metrics namespace confusion with legacy built-in metrics | Low | Medium | Clearly document plugin-specific metrics (`barman_cloud_cloudnative_pg_io_*`) in monitoring guide; update all alert rules |

---

## Next Steps

After completing Phase 0 and Phase 1 in this command (`/speckit.plan`):

1. **✓ Review Generated Artifacts**: Ensure `research.md`, `data-model.md` are complete and accurate
2. **Next: Generate contracts/**: Create CRD schemas and example manifests with plugin configuration
3. **Next: Generate quickstart.md**: Create operator guide with plugin-based setup
4. **Next: Run Agent Context Update**: Execute `.specify/scripts/bash/update-agent-context.sh opencode` to update agent memory
5. **Next: Validate Constitution Compliance**: Re-check all constitution items post-design
6. **Already Complete: Execute `/speckit.tasks`**: Task breakdown generated in `tasks.md`
7. **Begin Implementation**: Start with highest-priority tasks (P1: PostgreSQL cluster deployment) following task dependencies

---

## Notes

- This feature is **infrastructure-only** and does not modify the existing Rust application services
- All PostgreSQL configuration follows the **GitOps** pattern via FluxCD for consistency with the existing deployment workflow
- Existing Knative services remain unchanged; PostgreSQL is an **optional** backend database that services can connect to
- The implementation prioritizes **declarative manifests** over imperative tooling for operational simplicity
- Rust CLI tooling is **optional** and only needed if `kubectl`-based operations prove insufficient
- **Modern plugin architecture**: Uses Barman Cloud Plugin (`barman-cloud.cloudnative-pg.io`) with `ObjectStore` CRD instead of deprecated built-in `barmanObjectStore` configuration
- **Plugin-specific metrics**: Monitor backups using `barman_cloud_cloudnative_pg_io_*` metric namespace, not legacy `cnpg_collector_*` metrics
- **Explicit plugin references**: ScheduledBackup resources must use `method: plugin` and `pluginConfiguration` fields
- **SOPS encryption**: Secrets managed via SOPS + Age encryption for GitOps-friendly secret management
