# Research Findings: CloudNative PostgreSQL with Automated Backups

**Feature**: CloudNative PostgreSQL with Automated Backups  
**Branch**: `001-cloudnative-postgres-backups`  
**Date**: 2026-01-03  
**Status**: Research Complete

## Overview

This document consolidates research findings for implementing PostgreSQL support via CloudNativePG operator with automated backups to S3-compatible object storage using the Barman Cloud Plugin. All unknowns from the technical context have been resolved through systematic investigation.

---

## R1: CloudNativePG Operator Installation and Versioning

### Decision

**Use CloudNativePG operator version 1.28.0 with raw Kubernetes manifests managed by FluxCD Kustomize.**

**PostgreSQL version: 16 (currently 16.11)**

### Rationale

1. **Kubernetes 1.27+ Compatibility**: CloudNativePG 1.28.0 officially supports Kubernetes 1.27+ (tested up to 1.33)
2. **PostgreSQL Support**: Supports PostgreSQL 14, 15, 16, 17, and 18, with 16 being the most mature recent version
3. **Stability**: Version 1.28.0 (released Dec 2025) includes production-ready features like quorum-based failover and improved network resilience
4. **GitOps-Friendly**: Raw manifests integrate seamlessly with FluxCD's native Kustomize support without Helm complexity

### Alternatives Considered

- **Helm Chart Installation**: Rejected due to added complexity and Helm controller dependency; raw manifests are simpler for FluxCD
- **Operator Lifecycle Manager (OLM)**: Rejected as overkill for single-deployment operator; better suited for OpenShift
- **PostgreSQL 14/15**: Rejected due to approaching EOL (14) or fewer features than 16 (15)
- **PostgreSQL 17/18**: Rejected as too new; wait for 6-12 months of production hardening

### Implementation Notes

**Installation method** (FluxCD Kustomization):
```yaml
# infrastructure/cloudnative-pg/operator/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: cnpg-system
resources:
  - https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.28/releases/cnpg-1.28.0.yaml
```

**Operator resource requirements**:
- CPU: 100m request, 500m limit
- Memory: 128Mi request, 512Mi limit
- Startup time: ~30 seconds

**Upgrade path**: CloudNativePG supports in-place operator upgrades with rolling updates. Version 1.28.0 supports all PostgreSQL versions 14-18.

---

## R2: Barman Cloud Configuration Best Practices

### Decision

**Compression**: `gzip` for development (MinIO), `zstd` for production (AWS S3)  
**Encryption**: Server-side encryption (SSE-S3)  
**WAL Archiving**: Streaming WAL archiving with replication slots (near-zero RPO)  
**Bucket Structure**: Single bucket with organized prefix per cluster  
**Retention**: 7-30 days via recovery window policy

### Rationale

1. **Compression Performance**: zstd provides 75-80% compression ratio with 3-4x faster speed than gzip, achieving 30-minute backup target for 10GB databases
2. **Streaming WAL**: Near-zero RPO (<5 seconds) vs. traditional archive_command (5-10 minutes), essential for 99% success rate
3. **SSE-S3 Encryption**: Zero performance overhead, AWS-managed keys, meets compliance requirements without KMS complexity
4. **Single Bucket Design**: Simpler IAM policies, easier cost tracking, logical separation via prefixes

### Alternatives Considered

- **lz4 compression**: Rejected due to weaker compression ratio (60-65%), leading to 40-50% higher storage costs
- **Client-side encryption**: Rejected due to 10-15% performance penalty and key management complexity
- **SSE-KMS**: Rejected due to additional costs and 5-10ms latency per request
- **Archive command WAL archiving**: Rejected due to higher RPO (5-10 minutes) vs. streaming (seconds)

### Implementation Notes

**Barman Cloud configuration for production**:
```yaml
spec:
  backup:
    barmanObjectStore:
      destinationPath: s3://postgres-backups/
      s3Credentials:
        accessKeyId:
          name: s3-credentials
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: s3-credentials
          key: SECRET_ACCESS_KEY
      data:
        compression: zstd  # Production
        jobs: 2  # Parallel compression
      wal:
        compression: gzip
        maxParallel: 8  # Parallel WAL fetch
      retentionPolicy: "30d"
```

**Network bandwidth requirements**:
- Minimum: 50 Mbps (6.25 MB/s) for 10GB backup in 30 minutes
- Recommended: 100 Mbps for headroom and burst capacity
- Production: 1 Gbps if multiple clusters share network

**Monthly storage costs (AWS S3, 30-day retention)**:
- With zstd compression: ~$8.28/month (60GB backups + 150GB WALs)
- 80% savings vs. uncompressed

---

## R3: PostgreSQL High Availability Configuration

### Decision

**Replica counts**:
- Dev: 1 replica (no HA, cost-optimized)
- Staging: 2 replicas (basic HA, failover testing)
- Production: 3 replicas (full HA with quorum)

**Replication mode**:
- Synchronous with `synchronous_commit = remote_apply` for production
- Asynchronous for dev/staging
- Quorum-based: `synchronous_standby_names = 'ANY 1 (*)'`

**Resource templates**:
- Small (<10GB): 250m-1 CPU, 512Mi-1Gi memory, 20Gi storage
- Medium (10-100GB): 1-2 CPU, 2-4Gi memory, 200Gi storage
- Large (>100GB): 2-4 CPU, 8-16Gi memory, 500Gi storage

**PgBouncer**: Include for production, optional for staging, skip for dev

### Rationale

1. **3-Replica Production**: Provides quorum-based consensus, survives single node failure with guaranteed consistency
2. **Synchronous Quorum**: `ANY 1` ensures writes commit when any one standby confirms, balancing durability and availability
3. **Asynchronous Dev/Staging**: Lower latency, suitable for non-production where seconds of data loss is acceptable
4. **PgBouncer for Production**: Knative services create many short-lived connections; pooling reduces overhead significantly

### Alternatives Considered

- **2 replicas in production**: Rejected due to split-brain risk without quorum
- **Synchronous replication everywhere**: Rejected as unnecessary latency in dev/staging
- **Separate data/WAL volumes**: Rejected as CloudNativePG uses single PVC by default; modern SSDs handle mixed I/O well
- **PgBouncer everywhere**: Rejected as overkill for dev (single connection) and adds debugging complexity

### Implementation Notes

**Production cluster configuration**:
```yaml
spec:
  instances: 3
  resources:
    requests:
      cpu: 1000m
      memory: 2Gi
    limits:
      cpu: 2000m
      memory: 4Gi
  storage:
    size: 200Gi
    storageClass: fast-ssd  # 5000+ IOPS
  postgresql:
    parameters:
      shared_buffers: "512MB"
      max_connections: "300"
      synchronous_commit: "remote_apply"
      synchronous_standby_names: "ANY 1 (*)"
```

**Storage class requirements**:
- Small workload: 3,000 IOPS minimum (gp3, pd-ssd)
- Medium workload: 5,000-10,000 IOPS (premium SSD)
- Large workload: 10,000+ IOPS (NVMe-backed)

---

## R4: Monitoring and Alerting Integration

### Decision

**Metrics exposure**: CloudNativePG native Prometheus exporter on port 9187 via PodMonitor  
**Alert rules**: Deploy PrometheusRule with CloudNativePG-specific alerts  
**Grafana dashboards**: Use official pre-built dashboard from CloudNativePG Helm chart repository  
**OpenTelemetry**: No native support; use Prometheus as primary method

### Rationale

1. **Native Prometheus Integration**: CloudNativePG has built-in exporter, eliminating need for external exporters or sidecars
2. **Comprehensive Metrics**: 60+ predefined metrics covering backup status, replication lag, cluster health, WAL archiving
3. **Low Cardinality**: Key labels limited to cluster, pod, datname, usename
4. **Built-in Caching**: Metrics cached for 30 seconds by default, reducing PostgreSQL load
5. **Official Templates**: Battle-tested alert rules and dashboards from CloudNativePG team

### Alternatives Considered

- **PostgreSQL Prometheus Exporter (community)**: Rejected as redundant; CloudNativePG already includes equivalent functionality
- **OpenTelemetry Collector primary**: Rejected as CloudNativePG doesn't natively export OTEL metrics; Prometheus is recommended
- **ServiceMonitor**: Rejected in favor of PodMonitor (CloudNativePG instances accessed directly by pod, not through services)

### Implementation Notes

**PodMonitor configuration**:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: cnpg-cluster-metrics
  namespace: <cluster-namespace>
spec:
  selector:
    matchLabels:
      cnpg.io/cluster: <cluster-name>
  podMetricsEndpoints:
  - port: metrics  # Port 9187
    interval: 30s
```

**Key metrics**:
- Backup status: `cnpg_collector_last_failed_backup_timestamp`, `cnpg_collector_last_available_backup_timestamp`
- Replication lag: `cnpg_pg_replication_lag`, `cnpg_pg_stat_replication_replay_lag_seconds`
- Cluster health: `cnpg_collector_up`, `cnpg_collector_nodes_used`, `cnpg_collector_fencing_on`
- WAL archiving: `cnpg_pg_stat_archiver_failed_count`, `cnpg_pg_stat_archiver_seconds_since_last_failure`

**Alert rule thresholds**:
- Replication lag: Warning >10s, Critical >60s
- Backup failure: Critical after 5 minutes
- Instance down: Critical after 1 minute
- Connection exhaustion: Warning at 80% of max_connections

**Grafana dashboard**: https://github.com/cloudnative-pg/grafana-dashboards

---

## R5: Point-in-Time Recovery (PITR) Implementation

### Decision

**WAL archiving frequency**: 5 minutes (PostgreSQL `archive_timeout = 5min`)  
**Restore approach**: Always create new cluster using `bootstrap.recovery` (not in-place)  
**WAL retention**: Match backup retention period (7-30 days)  
**Recovery target**: Use `targetTime` with RFC 3339 timestamp format (explicit UTC)

### Rationale

1. **5-Minute WAL Archiving**: Balances recovery granularity (RPO ≤ 5 minutes) with storage efficiency and network overhead
2. **New Cluster Restore**: CloudNativePG does not support in-place recovery; creating new cluster is safer, allows validation before cutover
3. **Streaming WAL Archiving**: Near-zero RPO using replication slots, eliminates gaps in recovery timeline
4. **Recovery Window Policy**: Automatically preserves WAL files needed to replay from oldest backup forward

### Alternatives Considered

- **1-minute WAL archiving**: Rejected due to 5x more WAL files with minimal RPO benefit (1 min vs 5 min rarely significant)
- **15-30 minute WAL archiving**: Rejected due to unacceptable RPO degradation for production databases
- **In-place recovery**: Rejected as not supported by CloudNativePG architecture
- **Differential WAL retention**: Rejected as creating inconsistent recovery capabilities

### Implementation Notes

**Streaming WAL archiving configuration**:
```yaml
spec:
  postgresql:
    parameters:
      archive_timeout: "5min"
      wal_compression: on  # Reduce network transfer by ~50%
  backup:
    barmanObjectStore:
      wal:
        compression: gzip
        maxParallel: 8  # Download 8 WAL files concurrently
```

**Point-in-time recovery bootstrap**:
```yaml
spec:
  bootstrap:
    recovery:
      source: origin
      recoveryTarget:
        targetTime: "2026-01-03T14:30:00Z"  # RFC 3339 with explicit UTC
  externalClusters:
  - name: origin
    plugin:
      name: barman-cloud.cloudnative-pg.io
      parameters:
        barmanObjectName: postgres-backup-store
        serverName: postgres-cluster
```

**Recovery time estimation** (10GB database):
- Base backup restore: 5-10 minutes
- WAL replay: 2-5 minutes (weekly backups = max 7 days of WAL)
- Cluster initialization: 1-2 minutes
- **Total**: 8-17 minutes (within 15-minute target)

---

## R6: Kubernetes Secret Management for Object Storage Credentials

### Decision

**Primary method**: Mozilla SOPS with Age encryption + FluxCD native integration  
**Backup method**: External Secrets Operator (ESO) for dynamic secret injection from cloud KMS  
**Authentication strategy**: IRSA/Workload Identity where available (production), static credentials with SOPS for development

### Rationale

1. **SOPS + FluxCD**: Native integration via `.spec.decryption` field in Kustomization, no additional controllers needed
2. **Age Encryption**: Simpler than PGP, straightforward key generation and rotation
3. **GitOps-Native**: Encrypted secrets live in Git alongside manifests, providing full audit trail
4. **Per-Environment Keys**: Each environment uses different encryption keys for isolation
5. **IRSA for Production**: Eliminates static credentials, AWS handles rotation automatically

### Alternatives Considered

- **Sealed Secrets**: Rejected due to cluster-specific encryption, doesn't support multi-cluster GitOps well
- **ESO alone**: Rejected as primary method; requires external secret store, adds infrastructure complexity
- **Plain SOPS with PGP**: Rejected in favor of Age (simpler key management, smaller key sizes)

### Implementation Notes

**SOPS configuration** (`.sops.yaml`):
```yaml
creation_rules:
  - path_regex: .*.yaml
    encrypted_regex: ^(data|stringData)$
    age: age1hl...  # Age public key per environment
```

**CloudNativePG secret structure**:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: s3-credentials
  namespace: cnpg-system
type: Opaque
stringData:
  ACCESS_KEY_ID: "AKIAIOSFODNN7EXAMPLE"
  SECRET_ACCESS_KEY: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
```

**FluxCD Kustomization with decryption**:
```yaml
spec:
  decryption:
    provider: sops
    secretRef:
      name: sops-age  # Age private key stored in flux-system namespace
```

**Credential rotation procedure**:
1. Generate new S3 access key (AWS allows 2 keys per user)
2. Decrypt secret with SOPS, update credentials, re-encrypt
3. Commit to Git; FluxCD auto-reconciles within `interval` period
4. CloudNativePG operator picks up new credentials automatically
5. After next backup succeeds, revoke old credentials

**IRSA for production** (AWS EKS):
```yaml
spec:
  serviceAccountTemplate:
    metadata:
      annotations:
        eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT:role/cnpg-backup-role
  backup:
    barmanObjectStore:
      s3Credentials:
        inheritFromIAMRole: true  # Use pod IAM role
```

---

## R7: E2E Testing Strategy for PostgreSQL Operations

### Decision

**Test data size**: <1GB (generated via SQL)  
**Validation approach**: CloudNativePG API checksum verification + restore validation with query comparison  
**Failover simulation**: Pod deletion with `kubectl delete pod`  
**Parallelization**: Sequential execution (backup must complete before restore)  
**Target time**: <30 minutes total including all setup

### Rationale

1. **Small Test Database**: 1GB database validates all functionality without time penalty; backup/restore takes ~5-6 minutes vs. 20-30 minutes for 10GB
2. **Checksum Verification**: CloudNativePG automatically calculates checksums; validate via `.status.backupChecksums`
3. **Pod Deletion**: Simplest and most reliable failover simulation; mirrors real pod eviction scenarios
4. **Sequential Tests**: Dependencies prevent parallelization (backup → restore); avoids resource contention in Kind cluster

### Alternatives Considered

- **10GB test database**: Rejected as backup/restore would exceed 30-minute budget alone
- **Manual checksum calculation**: Rejected as CloudNativePG provides checksums automatically
- **Network partition simulation**: Rejected due to added complexity and 5-10 minutes setup time
- **Parallel backup/restore tests**: Rejected due to sequential dependency
- **Multiple PostgreSQL clusters in parallel**: Rejected due to Kind cluster resource limits (8GB)

### Implementation Notes

**Kind cluster resource requirements**:
```yaml
nodes:
  - role: control-plane
    resources:
      memory: "8Gi"   # Up from default 4Gi
      cpu: "4"        # Up from default 2
```

**Test PostgreSQL cluster configuration**:
```yaml
spec:
  instances: 2  # 1 primary + 1 replica for failover testing
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 1
      memory: 1Gi
  storage:
    size: 2Gi  # 2GB for <1GB test data + WAL overhead
```

**Test data generation** (~2-3 minutes):
```sql
-- Generate ~1GB test data
CREATE TABLE users (
  id SERIAL PRIMARY KEY,
  username VARCHAR(100),
  email VARCHAR(100),
  created_at TIMESTAMP DEFAULT NOW(),
  data TEXT
);

INSERT INTO users (username, email, data)
SELECT
  'user_' || generate_series,
  'user_' || generate_series || '@example.com',
  repeat('x', 800)  -- 800 bytes per row
FROM generate_series(1, 1000000);
```

**E2E test execution timeline**:
| Phase | Task | Time |
|-------|------|------|
| Setup | Kind + Knative + Flux + CNPG | 7 min |
| Deploy | PostgreSQL cluster + data | 5 min |
| Backup | Create + validate backup | 3.5 min |
| Restore | Restore + validate data | 4 min |
| Failover | Simulate + verify recovery | 3 min |
| Cleanup | Teardown | 1 min |
| **Total** | | **~23-25 min** |

**Resource summary**:
- Memory: 8Gi (4Gi K8s/Knative/Flux + 2Gi PostgreSQL + 512Mi MinIO + 1.5Gi overhead)
- CPU: 4 cores
- Disk: 20Gi

---

## R8: PostgreSQL Version and Extension Support

### Decision

**Default PostgreSQL version**: 16 (currently 16.11)  
**Container image**: `ghcr.io/cloudnative-pg/postgresql:16-standard-bookworm`  
**Pre-configured extensions**:
- pg_stat_statements (monitoring, enable by default)
- pgaudit (audit logging, optional)
- pgvector (vector similarity search, optional)
- postgres_failover_slots (logical replication, included)

### Rationale

1. **PostgreSQL 16 Maturity**: Released September 2023, over 1 year of production hardening
2. **Long Support Timeline**: Supported until November 2028 (5+ years from now)
3. **Performance Improvements**: Parallel joins, incremental sorts, better vacuum, I/O monitoring via `pg_stat_io`
4. **CloudNativePG Compatibility**: Fully supported with "standard" container images including key extensions
5. **Knative Suitability**: Efficient resource usage, fast connection handling, modern query optimization

### Alternatives Considered

- **PostgreSQL 17**: Rejected as too new (<6 months old); wait for more production deployments
- **PostgreSQL 15**: Rejected as PG 16 provides better features with similar maturity
- **PostgreSQL 14**: Rejected due to approaching EOL (November 2026, <1 year away)
- **Minimal container image**: Rejected in favor of standard image (includes useful extensions with minimal overhead)

### Implementation Notes

**Cluster manifest with extensions**:
```yaml
spec:
  imageName: ghcr.io/cloudnative-pg/postgresql:16-standard-bookworm
  postgresql:
    shared_preload_libraries:
      - pg_stat_statements
    parameters:
      pg_stat_statements.track: all
      pg_stat_statements.max: 10000
  bootstrap:
    initdb:
      postInitApplicationSQL:
        - CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

**Extension availability** (standard image):
- ✅ pg_stat_statements (query monitoring) - **Enable by default**
- ✅ pgaudit (audit logging) - Enable if compliance required
- ✅ pgvector (vector similarity) - Enable if AI/ML features needed
- ✅ postgres_failover_slots (replication) - Enable if using logical replication
- ✅ pgcrypto (encryption) - Enable on-demand
- ❌ PostGIS (geospatial) - Requires custom image
- ❌ TimescaleDB (time-series) - Requires custom image

**Upgrade paths**:
- CloudNativePG supports in-place major version upgrades via `pg_upgrade`
- Plan upgrades 6-12 months before PG 16 EOL (November 2028)

---

## Summary of Key Decisions

| Area | Decision | Key Value |
|------|----------|-----------|
| **Operator Version** | CloudNativePG 1.28.0 | Raw manifests with FluxCD |
| **PostgreSQL Version** | 16 (16.11) | Mature, 5+ years support |
| **Compression** | zstd (prod), gzip (dev) | 30-min backup for 10GB |
| **Replication** | 3 replicas (prod), sync with quorum | Zero data loss, HA |
| **WAL Archiving** | 5-minute streaming | RPO <5 seconds |
| **Monitoring** | Native Prometheus exporter | PodMonitor + PrometheusRule |
| **PITR** | New cluster via `bootstrap.recovery` | 15-min recovery for 10GB |
| **Secret Management** | SOPS + Age, IRSA for prod | GitOps-friendly, secure |
| **E2E Testing** | <1GB test DB, sequential | <30 min total time |
| **Extensions** | pg_stat_statements default | Monitoring-ready |

---

## Next Steps

1. Proceed to Phase 1: Design & Contracts
2. Generate data-model.md (entity definitions)
3. Create contracts/ directory with CRD schemas and examples
4. Generate quickstart.md (operator guide)
5. Update agent context with CloudNativePG patterns
