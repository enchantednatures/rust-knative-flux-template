# Feature Specification: CloudNative PostgreSQL with Automated Backups

**Feature Branch**: `001-cloudnative-postgres-backups`  
**Created**: 2026-01-03  
**Status**: Draft  
**Input**: User description: "i want to add support for a postgres server via cloudnative postgres with automated backups and restore using the barman object cloud plugin"

## Clarifications

### Session 2026-01-03

- Q: The CloudNativePG documentation shows that Barman Cloud backup is transitioning from built-in functionality to a plugin architecture (deprecated in v1.26+). Which approach should this implementation use? → A: Use Barman Cloud Plugin (`barman-cloud.cloudnative-pg.io`) with `ObjectStore` CRD - modern plugin architecture (recommended for CNPG 1.26+)
- Q: The spec mentions "incremental" backups in the Backup entity definition, but CloudNativePG with Barman Cloud currently only supports full base backups with continuous WAL archiving for incremental recovery. Should the system support incremental base backups or rely on WAL-based PITR? → A: Full backups only with WAL - CloudNativePG's standard approach provides PITR through WAL replay without true incremental base backups
- Q: The spec defines monitoring requirements using generic Prometheus metrics, but the Barman Cloud Plugin uses different metric names than the built-in CloudNativePG backup metrics. Which metric namespace should be used? → A: Use plugin-specific metrics (`barman_cloud_cloudnative_pg_io_*`) - aligns with plugin architecture
- Q: The spec doesn't specify how the Barman Cloud Plugin itself should be installed in the Kubernetes cluster. The plugin documentation shows it can be installed via Helm chart or raw manifests. Which installation method should be used? → A: Raw Kubernetes manifests managed by FluxCD - consistent with operator installation approach
- Q: The spec mentions that ScheduledBackup resources should use the plugin (FR-004), but doesn't specify whether ScheduledBackup CRDs need to be updated to reference the plugin explicitly or if they work automatically once the cluster is configured with the plugin. Which approach? → A: Explicit plugin reference in ScheduledBackup (method: plugin, pluginConfiguration) - clear and unambiguous

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Deploy PostgreSQL Cluster with High Availability (Priority: P1)

As a platform operator, I need to deploy a highly-available PostgreSQL cluster that can withstand node failures and provide continuous database service to applications, so that my applications have reliable data persistence without manual intervention.

**Why this priority**: This is the foundational capability. Without a working PostgreSQL cluster, no other features (backups, restores) have value. This represents the minimum viable product.

**Independent Test**: Deploy a PostgreSQL cluster to a Kubernetes environment, verify that all replicas are running and healthy, confirm that applications can connect and execute queries successfully, and demonstrate that the cluster remains available when a single pod is terminated.

**Acceptance Scenarios**:

1. **Given** a Kubernetes cluster with CloudNativePG operator installed, **When** a PostgreSQL cluster manifest is applied, **Then** the cluster reaches a healthy state with the specified number of replicas running within 5 minutes.
2. **Given** a healthy PostgreSQL cluster, **When** an application connects using the cluster service endpoint, **Then** the connection succeeds and queries execute successfully.
3. **Given** a PostgreSQL cluster with 3 replicas, **When** one replica pod is deleted, **Then** the cluster automatically recovers by promoting a replica or restarting the pod within 2 minutes without service disruption.

---

### User Story 2 - Automated Daily Backups to Object Storage (Priority: P2)

As a platform operator, I need PostgreSQL backups to be automatically created and stored in object storage on a scheduled basis, so that I have point-in-time recovery capability and can meet compliance requirements for data retention without manual backup operations.

**Why this priority**: This provides data safety and recovery capability. Once the cluster is operational (P1), automated backups are the next critical feature to prevent data loss. This can be tested independently from restore operations.

**Independent Test**: Configure a backup schedule for an existing PostgreSQL cluster, wait for the scheduled backup time to pass, verify that backup files appear in the configured object storage bucket, and confirm that backup metadata shows successful completion with size and timestamp information.

**Acceptance Scenarios**:

1. **Given** a running PostgreSQL cluster with backup configuration defined, **When** the scheduled backup time arrives, **Then** a full backup is created and uploaded to object storage within 30 minutes for databases up to 10GB.
2. **Given** a backup configuration with retention policy set to 7 days, **When** backups older than 7 days exist, **Then** the system automatically removes expired backups from object storage.
3. **Given** a PostgreSQL cluster with active transactions, **When** a scheduled backup runs, **Then** the backup completes without disrupting active database connections or queries.
4. **Given** a failed backup attempt, **When** the failure is detected, **Then** the system logs the error with sufficient detail for troubleshooting and alerts are generated.

---

### User Story 3 - Point-in-Time Database Restore (Priority: P3)

As a platform operator, I need to restore a PostgreSQL database from a backup to a specific point in time, so that I can recover from data corruption, accidental deletion, or security incidents by reverting the database state to a known-good configuration.

**Why this priority**: This completes the backup/restore lifecycle but has lower priority because it's used infrequently (only during incidents). The cluster can operate successfully with just P1 and P2, and restore functionality can be added and tested later.

**Independent Test**: Using an existing backup from object storage, create a restore request specifying a target timestamp, verify that a new PostgreSQL cluster is created with data restored to the requested point in time, and confirm that the restored data matches the expected state at that timestamp.

**Acceptance Scenarios**:

1. **Given** a valid backup exists in object storage, **When** a restore operation is initiated with a specific backup identifier, **Then** a new PostgreSQL cluster is created with data restored from that backup within 15 minutes for databases up to 10GB.
2. **Given** continuous WAL archiving is enabled, **When** a restore request specifies a point-in-time timestamp between backups, **Then** the system restores to the exact requested timestamp by replaying WAL files.
3. **Given** a restore operation in progress, **When** the operation fails due to corrupted backup files, **Then** the system reports the failure with specific error details and does not leave partial or inconsistent data.
4. **Given** a successful restore, **When** applications connect to the restored database, **Then** the data integrity is maintained and all constraints, indexes, and relationships are preserved.

---

### User Story 4 - Monitor Backup Health and Storage Usage (Priority: P3)

As a platform operator, I need visibility into backup status, success rates, storage consumption, and backup duration trends, so that I can proactively identify issues before they impact recovery capability and optimize storage costs.

**Why this priority**: Observability is important for operational excellence but the backups can function without dashboards. This is a quality-of-life improvement that can be added after core backup functionality works.

**Independent Test**: Query backup metrics and status information, verify that backup success/failure counts are accurate, confirm that storage usage metrics reflect actual object storage consumption, and validate that alerts fire when backup failures occur.

**Acceptance Scenarios**:

1. **Given** multiple backup operations have completed, **When** metrics are queried, **Then** backup success rate, duration, and size metrics are available with correct values.
2. **Given** a backup failure occurs, **When** the failure is detected, **Then** an alert is generated within 5 minutes with actionable information about the failure cause.
3. **Given** object storage costs are a concern, **When** storage metrics are reviewed, **Then** operators can identify which clusters consume the most backup storage and adjust retention policies accordingly.

---

### Edge Cases

- What happens when object storage becomes unavailable during a scheduled backup? System should retry with exponential backoff and log failures without crashing the cluster.
- How does the system handle backup requests when the database is under heavy write load? Backups should not block writes or significantly impact application performance.
- What happens when a restore is initiated but insufficient storage is available in the cluster? The restore operation should fail gracefully with a clear error message before attempting data transfer.
- How does the system handle timezone differences between backup timestamps and restore requests? All timestamps should use UTC to avoid ambiguity.
- What happens when attempting to restore a backup from a different PostgreSQL major version? The system should validate version compatibility and either succeed with warnings or fail with clear guidance.
- How does the system handle partial backup uploads due to network interruptions? Incomplete backups should be marked as failed and not considered valid for restore operations.
- What happens when retention policies would delete the last available backup? The system should preserve at least one backup regardless of age unless explicitly overridden.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST deploy PostgreSQL clusters with configurable replica count (minimum 1, recommended 3 for high availability).
- **FR-002**: System MUST automatically elect a new primary when the current primary fails, promoting a replica within 60 seconds.
- **FR-003**: System MUST provide distinct connection endpoints for read-write (primary) and read-only (replica) operations.
- **FR-004**: System MUST schedule automated backups based on user-defined cron expressions (e.g., daily at 2 AM) via `ScheduledBackup` resources that explicitly reference the plugin using `method: plugin` and `pluginConfiguration.name: barman-cloud.cloudnative-pg.io`.
- **FR-005**: System MUST upload backup files to object storage using the Barman Cloud Plugin (`barman-cloud.cloudnative-pg.io`) with `ObjectStore` CRD for backup configuration.
- **FR-006**: System MUST support object storage providers that are S3-compatible.
- **FR-007**: System MUST continuously archive Write-Ahead Log (WAL) files to object storage for point-in-time recovery capability.
- **FR-008**: System MUST apply retention policies to automatically remove backups older than the configured retention period.
- **FR-009**: System MUST validate backup integrity after upload completion by verifying checksums.
- **FR-010**: System MUST allow operators to restore a PostgreSQL cluster from a specific backup by referencing the backup identifier.
- **FR-011**: System MUST support point-in-time recovery by specifying a target timestamp, replaying WAL files to reach the exact state at that moment.
- **FR-012**: System MUST create restored clusters as independent PostgreSQL instances, not overwriting the existing cluster.
- **FR-013**: System MUST provide status information for each backup including start time, completion time, size, and success/failure state.
- **FR-014**: System MUST prevent simultaneous full backups on the same cluster to avoid resource contention.
- **FR-015**: System MUST authenticate to object storage using credentials provided via Kubernetes secrets.
- **FR-016**: System MUST support configurable storage classes for PostgreSQL persistent volumes to accommodate different performance requirements.
- **FR-017**: System MUST allow configuration of PostgreSQL parameters (memory, connections, shared buffers) through cluster manifests.
- **FR-018**: System MUST expose cluster health status including replica count, replication lag, and connection availability.

### Non-Functional Requirements *(mandatory per constitution)*

- **NFR-001**: All backup operations MUST be logged with structured logging including cluster name, backup type, duration, and outcome.
- **NFR-002**: All backup and restore operations MUST emit Prometheus-compatible metrics including success count, failure count, duration histogram, and backup size. Plugin-based deployments will use the `barman_cloud_cloudnative_pg_io_*` metric namespace (e.g., `barman_cloud_cloudnative_pg_io_last_failed_backup_timestamp`, `barman_cloud_cloudnative_pg_io_last_available_backup_timestamp`, `barman_cloud_cloudnative_pg_io_first_recoverability_point`).
- **NFR-003**: System MUST propagate distributed tracing context from Kubernetes events to backup operations for end-to-end observability.
- **NFR-004**: Backup configuration MUST support environment-specific overrides via environment variables or ConfigMaps (e.g., different object storage buckets per environment).
- **NFR-005**: All errors during backup and restore operations MUST be logged with sufficient context (cluster name, operation ID, error message, stack trace) for troubleshooting.
- **NFR-006**: PostgreSQL cluster startup time SHOULD be under 90 seconds for clusters with less than 100GB of data.
- **NFR-007**: Backup operations SHOULD complete within 30 minutes for databases up to 10GB, with time scaling linearly for larger databases.
- **NFR-008**: Replication lag between primary and replicas SHOULD remain under 10 seconds during normal operation.
- **NFR-009**: System MUST handle transient object storage errors with retry logic (3 retries with exponential backoff).
- **NFR-010**: Backup retention policy enforcement MUST run at least once per day to free storage space.
- **NFR-011**: All sensitive credentials (object storage access keys) MUST be stored in Kubernetes secrets and never logged or exposed in metrics.
- **NFR-012**: System MUST support GitOps workflows by allowing all PostgreSQL and backup configurations to be defined as declarative YAML manifests.

### Key Entities

- **PostgreSQL Cluster**: A logical database cluster consisting of one primary instance and zero or more replica instances, managed as a cohesive unit with automatic failover capability. Attributes include cluster name, replica count, PostgreSQL version, resource limits (CPU, memory, storage), and connection endpoints.

- **Backup**: A point-in-time snapshot of a PostgreSQL cluster's data, stored in object storage. Attributes include backup identifier, cluster name, backup type (full base backup), start timestamp, completion timestamp, size in bytes, status (in-progress, completed, failed), and object storage location. Point-in-time recovery is achieved through continuous WAL archiving, not incremental base backups.

- **Restore Operation**: A request to create a new PostgreSQL cluster by recovering data from a specific backup or point in time. Attributes include restore identifier, source backup identifier, target point-in-time timestamp (optional), target cluster name, status (requested, in-progress, completed, failed), and start/completion timestamps.

- **Backup Configuration**: The policy defining when and how backups are created and retained. Attributes include schedule (cron expression), retention period (days), object storage endpoint, storage bucket name, compression settings, and encryption settings. Implemented via `ObjectStore` custom resource managed by the Barman Cloud Plugin.

- **Object Storage Credentials**: Authentication information required to access object storage for backup uploads and downloads. Attributes include access key ID, secret access key, endpoint URL, bucket name, and optional encryption keys. Stored securely in Kubernetes secrets.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Operators can deploy a new PostgreSQL cluster and have it ready to accept connections within 5 minutes of applying the cluster manifest.
- **SC-002**: Automated backups complete successfully for 99% of scheduled backup operations over a 30-day period.
- **SC-003**: Backup operations for a 10GB database complete within 30 minutes from start to successful upload to object storage.
- **SC-004**: PostgreSQL clusters automatically recover from primary node failure within 2 minutes without manual intervention.
- **SC-005**: Operators can restore a database from backup to a specific point in time within 15 minutes for databases up to 10GB.
- **SC-006**: Backup storage costs are reduced by 50% compared to storing backups on persistent volumes, due to object storage pricing and compression.
- **SC-007**: Zero data loss occurs during replica promotion when primary fails, assuming WAL archiving is enabled.
- **SC-008**: Operators can identify backup failures within 5 minutes through alerts and monitoring dashboards.
- **SC-009**: 95% of backup-related incidents are resolved using information from logs and metrics without needing to access cluster internals.
- **SC-010**: Retention policies successfully free object storage space within 24 hours of backups exceeding the retention period.

## Assumptions

- The Kubernetes cluster has the CloudNativePG operator (v1.26+) and Barman Cloud Plugin installed and operational via raw Kubernetes manifests managed by FluxCD.
- Object storage infrastructure (S3-compatible) is available and accessible from the Kubernetes cluster network.
- Operators have the necessary credentials and permissions to create Kubernetes resources and manage object storage buckets.
- The platform supports persistent volume provisioning for PostgreSQL data storage.
- Monitoring infrastructure (Prometheus) is available to collect metrics from PostgreSQL clusters and backup operations.
- Network bandwidth between Kubernetes cluster and object storage is sufficient for backup uploads (minimum 100 Mbps recommended).
- Operators are familiar with Kubernetes concepts including manifests, secrets, ConfigMaps, and kubectl commands.
- PostgreSQL version 14 or later is used, as CloudNativePG has best support for recent versions.
- Backup retention periods follow typical enterprise standards (7 to 30 days) unless compliance requirements dictate otherwise.
- Point-in-time recovery windows match the WAL archive retention period (typically same as backup retention).
