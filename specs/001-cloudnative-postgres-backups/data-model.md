# Data Model: CloudNative PostgreSQL with Automated Backups

**Feature**: CloudNative PostgreSQL with Automated Backups  
**Branch**: `001-cloudnative-postgres-backups`  
**Date**: 2026-01-03  
**Status**: Phase 1 Complete

## Overview

This document defines the data entities and their relationships for the PostgreSQL database infrastructure managed by CloudNativePG. These entities represent the logical data model from an operational perspective, abstracting away implementation details.

---

## Entity Definitions

### 1. PostgreSQL Cluster

**Description**: A logical database cluster consisting of one primary instance and zero or more replica instances, managed as a cohesive unit with automatic failover capability.

**Attributes**:

| Attribute | Type | Description | Constraints |
|-----------|------|-------------|-------------|
| cluster_name | String | Unique identifier for the cluster | Required, must be valid Kubernetes resource name (RFC 1123) |
| replica_count | Integer | Number of total instances (primary + replicas) | 1-5, recommended: 1 (dev), 2 (staging), 3 (prod) |
| postgresql_version | String | PostgreSQL major version | 14, 15, or 16 (16 recommended) |
| cpu_request | String | Kubernetes CPU resource request | e.g., "500m", "1", "2" |
| cpu_limit | String | Kubernetes CPU resource limit | e.g., "1", "2", "4" |
| memory_request | String | Kubernetes memory resource request | e.g., "512Mi", "2Gi", "8Gi" |
| memory_limit | String | Kubernetes memory resource limit | e.g., "1Gi", "4Gi", "16Gi" |
| storage_size | String | Persistent volume size | e.g., "20Gi", "200Gi", "500Gi" |
| storage_class | String | Kubernetes storage class name | Must support ReadWriteOnce, minimum 3000 IOPS |
| primary_endpoint | String | Connection endpoint for read-write operations | Format: `<cluster-name>-rw.<namespace>.svc` |
| replica_endpoint | String | Connection endpoint for read-only operations | Format: `<cluster-name>-ro.<namespace>.svc` |
| state | Enum | Current cluster state | Values: creating, ready, updating, failed, switchover, fenced |
| replication_mode | Enum | Replication synchronization mode | Values: async, sync, quorum |
| created_at | Timestamp | Cluster creation timestamp | UTC timezone |
| updated_at | Timestamp | Last update timestamp | UTC timezone |

**State Transitions**:
- creating → ready (successful deployment)
- creating → failed (deployment error)
- ready → updating (configuration change)
- updating → ready (update complete)
- ready → switchover (manual failover triggered)
- switchover → ready (new primary elected)
- ready → fenced (cluster fenced due to split-brain detection)

**Validation Rules**:
- replica_count must be at least 1
- For production environments (replication_mode = sync or quorum), replica_count should be ≥ 3
- storage_size must accommodate actual data + WAL files + 20% growth buffer
- memory_limit must be at least 2x memory_request
- cpu_limit must be at least 1x cpu_request

**Example Values** (Production):
```
cluster_name: "app-db-prod"
replica_count: 3
postgresql_version: "16"
cpu_request: "1"
cpu_limit: "2"
memory_request: "2Gi"
memory_limit: "4Gi"
storage_size: "200Gi"
storage_class: "fast-ssd"
primary_endpoint: "app-db-prod-rw.services.svc"
replica_endpoint: "app-db-prod-ro.services.svc"
state: ready
replication_mode: quorum
```

---

### 2. Backup

**Description**: A point-in-time snapshot of a PostgreSQL cluster's data, stored in object storage.

**Attributes**:

| Attribute | Type | Description | Constraints |
|-----------|------|-------------|-------------|
| backup_id | String | Unique identifier for the backup | Format: `<cluster-name>-<timestamp>`, e.g., "app-db-20260103T020000" |
| cluster_name | String | Reference to the source PostgreSQL cluster | Must exist as a PostgreSQL Cluster entity |
| backup_type | Enum | Type of backup | Values: full, incremental (currently only full supported by CloudNativePG) |
| status | Enum | Current backup status | Values: in-progress, completed, failed |
| start_timestamp | Timestamp | Backup initiation time | UTC timezone |
| completion_timestamp | Timestamp | Backup completion time | UTC timezone, null if not completed |
| size_bytes | Integer | Uncompressed backup size in bytes | Null if not completed, >0 when completed |
| compressed_size_bytes | Integer | Compressed backup size in object storage | Null if not completed |
| compression_ratio | Float | Compression effectiveness | Calculated: size_bytes / compressed_size_bytes |
| object_storage_location | String | Full path to backup in object storage | Format: `s3://<bucket>/<cluster-name>/base/<backup-id>/` |
| checksum | String | Integrity verification checksum | SHA256 hash, computed by CloudNativePG |
| wal_start_lsn | String | Write-Ahead Log start Log Sequence Number | PostgreSQL LSN format, e.g., "0/3000028" |
| wal_end_lsn | String | Write-Ahead Log end Log Sequence Number | PostgreSQL LSN format |
| error_message | String | Error details if backup failed | Null if successful, populated on failure |

**State Transitions**:
- null → in-progress (backup initiated)
- in-progress → completed (backup uploaded successfully)
- in-progress → failed (backup error occurred)

**Validation Rules**:
- completion_timestamp must be after start_timestamp
- size_bytes must be > 0 when status = completed
- checksum must be present when status = completed
- compression_ratio typically ranges from 0.2 to 0.4 (depending on compression algorithm)
- error_message must be populated when status = failed

**Relationships**:
- Belongs to one PostgreSQL Cluster (many backups per cluster)
- Can be source for many Restore Operations

**Example Values**:
```
backup_id: "app-db-prod-20260103T020000"
cluster_name: "app-db-prod"
backup_type: full
status: completed
start_timestamp: 2026-01-03T02:00:00Z
completion_timestamp: 2026-01-03T02:23:15Z
size_bytes: 10737418240  # 10GB
compressed_size_bytes: 2684354560  # 2.5GB
compression_ratio: 0.25  # 75% compression
object_storage_location: "s3://postgres-backups-prod/app-db-prod/base/20260103T020000/"
checksum: "sha256:a3b5c..."
wal_start_lsn: "0/3000028"
wal_end_lsn: "0/30A4F20"
error_message: null
```

---

### 3. Backup Configuration

**Description**: The policy defining when and how backups are created and retained for a PostgreSQL cluster.

**Attributes**:

| Attribute | Type | Description | Constraints |
|-----------|------|-------------|-------------|
| config_id | String | Unique identifier for the configuration | Format: `<cluster-name>-backup-config` |
| cluster_name | String | Reference to the target PostgreSQL cluster | Must exist as a PostgreSQL Cluster entity |
| schedule_cron | String | Cron expression defining backup frequency | Valid cron format, e.g., "0 2 * * *" (daily at 2 AM) |
| retention_days | Integer | Number of days to retain backups | 1-365, typical: 7 (dev), 14 (staging), 30 (prod) |
| object_storage_endpoint | String | S3-compatible object storage URL | Format: `https://s3.amazonaws.com` or `http://minio:9000` |
| bucket_name | String | Object storage bucket name | Must be valid S3 bucket name |
| compression_algorithm | Enum | Backup compression method | Values: gzip, zstd, none (zstd recommended for prod) |
| compression_level | Integer | Compression intensity | 1-9 for gzip, 1-22 for zstd (3 recommended for zstd) |
| encryption_enabled | Boolean | Whether server-side encryption is enabled | true for prod, can be false for dev |
| wal_archive_enabled | Boolean | Whether WAL archiving is active | true (required for PITR) |
| wal_compression | Enum | WAL file compression | Values: gzip, zstd, none |
| wal_parallel_upload | Integer | Number of parallel WAL uploads | 1-16, recommended: 2 (dev), 8 (prod) |
| enabled | Boolean | Whether scheduled backups are active | true to activate |

**Validation Rules**:
- schedule_cron must be valid cron expression
- retention_days must be > 0
- If wal_archive_enabled = true, wal_compression should not be none
- compression_level must be within valid range for compression_algorithm
- wal_parallel_upload should not exceed 16 (diminishing returns)

**Relationships**:
- Belongs to exactly one PostgreSQL Cluster (one config per cluster)
- References Object Storage Credentials (via secret)

**Example Values** (Production):
```
config_id: "app-db-prod-backup-config"
cluster_name: "app-db-prod"
schedule_cron: "0 2 * * *"  # Daily at 2 AM
retention_days: 30
object_storage_endpoint: "https://s3.amazonaws.com"
bucket_name: "postgres-backups-prod"
compression_algorithm: zstd
compression_level: 3
encryption_enabled: true
wal_archive_enabled: true
wal_compression: gzip
wal_parallel_upload: 8
enabled: true
```

---

### 4. Restore Operation

**Description**: A request to create a new PostgreSQL cluster by recovering data from a specific backup or point in time.

**Attributes**:

| Attribute | Type | Description | Constraints |
|-----------|------|-------------|-------------|
| restore_id | String | Unique identifier for the restore operation | Format: `<cluster-name>-restore-<timestamp>` |
| source_backup_id | String | Reference to the source backup | Can be null if target_pitr_timestamp is specified (auto-selects backup) |
| target_pitr_timestamp | Timestamp | Point-in-time recovery target | UTC timezone, RFC 3339 format, can be null for latest |
| target_cluster_name | String | Name of the new cluster to create | Must be unique, valid Kubernetes resource name |
| status | Enum | Current restore status | Values: requested, in-progress, completed, failed |
| start_timestamp | Timestamp | Restore initiation time | UTC timezone |
| completion_timestamp | Timestamp | Restore completion time | UTC timezone, null if not completed |
| error_message | String | Error details if restore failed | Null if successful |
| recovery_method | Enum | Recovery strategy used | Values: backup_only, pitr (point-in-time recovery) |
| wal_replay_count | Integer | Number of WAL files replayed | 0 if backup_only, >0 for pitr |

**State Transitions**:
- null → requested (restore operation created)
- requested → in-progress (recovery started)
- in-progress → completed (new cluster ready)
- in-progress → failed (recovery error)

**Validation Rules**:
- Either source_backup_id OR target_pitr_timestamp must be specified
- If target_pitr_timestamp is specified, it must be within the recovery window (backup retention period)
- target_cluster_name must not conflict with existing clusters
- completion_timestamp must be after start_timestamp
- error_message must be populated when status = failed

**Relationships**:
- References one Backup (via source_backup_id or auto-selected for PITR)
- Creates one new PostgreSQL Cluster (target_cluster_name)

**Example Values** (PITR):
```
restore_id: "app-db-prod-restore-20260103T140000"
source_backup_id: null  # Auto-selected by CloudNativePG
target_pitr_timestamp: 2026-01-03T14:30:00Z
target_cluster_name: "app-db-prod-restored"
status: completed
start_timestamp: 2026-01-03T14:35:00Z
completion_timestamp: 2026-01-03T14:47:23Z
error_message: null
recovery_method: pitr
wal_replay_count: 142
```

---

### 5. Object Storage Credentials

**Description**: Authentication information required to access object storage for backup uploads and downloads. Stored securely in Kubernetes secrets.

**Attributes**:

| Attribute | Type | Description | Constraints |
|-----------|------|-------------|-------------|
| credential_id | String | Unique identifier for the credentials | Format: `<environment>-s3-credentials` |
| access_key_id | String (sensitive) | S3 access key identifier | AWS IAM access key format, encrypted at rest |
| secret_access_key | String (sensitive) | S3 secret access key | AWS IAM secret key format, encrypted at rest |
| endpoint_url | String | Object storage endpoint | Format: `https://s3.amazonaws.com` or `http://minio:9000` |
| bucket_name | String | Default bucket for operations | Must be valid S3 bucket name |
| region | String | AWS region (if applicable) | e.g., "us-east-1", can be empty for MinIO |
| use_irsa | Boolean | Whether to use IAM Roles for Service Accounts | true for production (eliminates static credentials) |
| session_token | String (sensitive) | Temporary session token (if use_irsa = true) | Auto-rotated by AWS, short-lived |
| created_at | Timestamp | Credential creation time | UTC timezone |
| last_rotated_at | Timestamp | Last credential rotation time | UTC timezone |

**Validation Rules**:
- If use_irsa = false, access_key_id and secret_access_key must be present
- If use_irsa = true, session_token is managed by AWS and auto-rotated
- Credentials should be rotated every 90 days (security best practice)
- bucket_name must exist and be accessible with these credentials

**Security Requirements**:
- Never log access_key_id, secret_access_key, or session_token
- Store in Kubernetes secrets, encrypted with SOPS/Age for GitOps
- Use IRSA/Workload Identity in production to eliminate static credentials
- Implement credential rotation without downtime (dual-key approach)

**Relationships**:
- Referenced by one or more Backup Configurations
- One credential set per environment (dev, staging, prod)

**Example Values** (Production with IRSA):
```
credential_id: "prod-s3-credentials"
access_key_id: null  # Not used with IRSA
secret_access_key: null  # Not used with IRSA
endpoint_url: "https://s3.amazonaws.com"
bucket_name: "postgres-backups-prod"
region: "us-east-1"
use_irsa: true
session_token: "<auto-rotated by AWS>"
created_at: 2026-01-01T00:00:00Z
last_rotated_at: 2026-01-03T00:00:00Z  # Auto-rotated
```

---

## Entity Relationships

### Relationship Diagram

```
┌─────────────────────────┐
│  PostgreSQL Cluster     │
│                         │
│  - cluster_name (PK)    │
│  - replica_count        │
│  - postgresql_version   │
│  - state                │
└──────────┬──────────────┘
           │
           │ 1:N (one cluster has many backups)
           │
           ▼
┌─────────────────────────┐
│  Backup                 │
│                         │
│  - backup_id (PK)       │
│  - cluster_name (FK)    │◄────────────┐
│  - status               │             │
│  - checksum             │             │
└──────────┬──────────────┘             │
           │                            │
           │ 1:N (one backup can be     │ N:1 (many restores
           │      restored many times)  │      from one backup)
           │                            │
           ▼                            │
┌─────────────────────────┐             │
│  Restore Operation      │             │
│                         │             │
│  - restore_id (PK)      │             │
│  - source_backup_id (FK)├─────────────┘
│  - target_cluster_name  │
│  - status               │
└─────────────────────────┘


┌─────────────────────────┐         ┌──────────────────────────┐
│  PostgreSQL Cluster     │         │ Object Storage Credentials│
└──────────┬──────────────┘         │                          │
           │                        │  - credential_id (PK)    │
           │ 1:1                    │  - access_key_id         │
           │                        │  - secret_access_key     │
           ▼                        └────────────┬─────────────┘
┌─────────────────────────┐                     │
│  Backup Configuration   │                     │
│                         │◄────────────────────┘ N:1 (many configs
│  - config_id (PK)       │                           use one credential)
│  - cluster_name (FK)    │
│  - schedule_cron        │
│  - retention_days       │
└─────────────────────────┘
```

### Relationship Descriptions

**PostgreSQL Cluster → Backup (1:N)**:
- One PostgreSQL Cluster can have many Backups
- Each Backup belongs to exactly one PostgreSQL Cluster
- Backups are created according to Backup Configuration schedule
- When a cluster is deleted, backups can be retained or deleted based on policy

**Backup → Restore Operation (1:N)**:
- One Backup can be source for many Restore Operations
- Each Restore Operation uses one Backup (or auto-selects for PITR)
- Restore Operations create new, independent PostgreSQL Clusters

**PostgreSQL Cluster → Backup Configuration (1:1)**:
- Each PostgreSQL Cluster has exactly one Backup Configuration
- Backup Configuration defines schedule, retention, and object storage settings
- Configuration can be modified without affecting existing backups

**Backup Configuration → Object Storage Credentials (N:1)**:
- Many Backup Configurations can share one set of Object Storage Credentials
- Typically one credential set per environment (dev/staging/prod)
- Credentials are stored in Kubernetes secrets, referenced by name

---

## Data Lifecycle and Retention

### Backup Retention

**Retention Policy**: Recovery window-based (e.g., 30 days)
- Oldest backup before Point of Recoverability (current time - 30d) is preserved
- All subsequent backups up to present are preserved
- Backups older than recovery window + 1 day are deleted automatically

**WAL Retention**: Matches backup retention
- WAL files needed to replay from oldest backup to present are preserved
- WAL files older than oldest backup are automatically deleted

**Retention Enforcement**: Runs at least once per day (typically after successful backup)

### Cluster Lifecycle

**Creation**: Cluster state progresses from creating → ready (60-90 seconds)
**Updates**: Configuration changes trigger state transition ready → updating → ready
**Failover**: Primary failure triggers state transition ready → switchover → ready (<2 minutes)
**Deletion**: Cluster can be deleted, optionally preserving or deleting associated backups

### Restore Lifecycle

**Initiation**: Restore Operation created in requested state
**Execution**: Progresses to in-progress → downloads backup → replays WAL → creates new cluster
**Completion**: Reaches completed state when new cluster is ready for connections
**Failure**: If error occurs, reaches failed state with error_message populated

---

## Capacity Planning Guidelines

### Storage Estimation

**PostgreSQL Cluster Storage Size** = (Actual Data Size) × 1.5 + (WAL Buffer)
- **Actual Data Size**: Current database size
- **1.5x Multiplier**: Accommodates indexes, temporary tables, growth
- **WAL Buffer**: Typically 10-20GB for wal_keep_size

**Example**: 100GB database → 150GB + 20GB = **170GB storage_size** (round up to 200GB)

### Backup Storage Estimation

**Monthly Backup Storage** = (Backup Size) × (Backups per Month) + (WAL Size)
- **Backup Size**: Database Size × Compression Ratio (0.20-0.30 for zstd)
- **Backups per Month**: Depends on schedule (daily = ~30, weekly = ~4)
- **WAL Size**: Daily Write Volume × Retention Days × Compression Ratio (0.50 for gzip)

**Example** (100GB database, 30-day retention, daily backups, 10GB writes/day):
- Backup storage: 100GB × 0.25 × 30 = 750GB
- WAL storage: 10GB × 30 × 0.50 = 150GB
- **Total: ~900GB S3 storage** (~$20.70/month on AWS S3 Standard)

### Memory Sizing

**PostgreSQL shared_buffers** = 25% of allocated memory (PostgreSQL best practice)
**Total Memory** = shared_buffers + (work_mem × max_connections) + OS overhead

**Example**: For 200 connections with 4MB work_mem:
- shared_buffers: 512MB (from 2Gi total)
- work_mem pool: 800MB (200 × 4MB)
- OS overhead: ~700MB
- **Total: 2Gi memory_limit**

---

## Consistency and Integrity

### Backup Integrity

**Checksums**: Every backup has SHA256 checksum computed by CloudNativePG
**Validation**: Checksums verified on restore to detect corruption
**Atomic Uploads**: Backup marked complete only after all files uploaded successfully
**Partial Backup Handling**: Incomplete backups marked as failed, not used for restore

### Replication Consistency

**Synchronous Replication** (production): Zero data loss, writes wait for replica acknowledgment
**Quorum Replication**: Writes commit when ANY 1 of N replicas acknowledges (balances availability and consistency)
**Asynchronous Replication** (dev/staging): Lower latency, potential RPO of seconds

### Recovery Consistency

**Point-in-Time Recovery**: WAL replay ensures database state is consistent at target timestamp
**Crash Recovery**: PostgreSQL ensures consistency even if restore is interrupted
**Validation**: Restored cluster undergoes automatic consistency checks before accepting connections

---

## Next Steps

1. Create contracts/ directory with CRD schemas and example manifests
2. Generate quickstart.md with operator procedures
3. Update agent context with CloudNativePG patterns
