# PostgreSQL Backup and Restore Procedures

Complete guide for backing up, restoring, and performing point-in-time recovery of PostgreSQL databases.

## Table of Contents

1. [Backup Overview](#backup-overview)
2. [Backup Configuration](#backup-configuration)
3. [Manual Backup Procedures](#manual-backup-procedures)
4. [Scheduled Backups](#scheduled-backups)
5. [Restore Procedures](#restore-procedures)
6. [Point-in-Time Recovery](#point-in-time-recovery)
7. [Disaster Recovery](#disaster-recovery)
8. [Backup Verification](#backup-verification)
9. [Troubleshooting](#troubleshooting)

## Backup Overview

### Backup Methods

CloudNativePG uses **Barman Cloud Plugin** for backups to object storage:

- **Method**: Plugin (Barman Cloud Plugin)
- **Transport**: Streaming WAL archiving + base backups
- **Compression**: Configurable (gzip, zstd)
- **Encryption**: Optional (SSE-S3 for AWS S3)
- **Retention**: Automatic cleanup based on retention policy

### Backup Components

1. **Base Backup**: Full database snapshot (binary copy)
2. **WAL Archive**: Transaction logs for recovery between base backups
3. **Backup Metadata**: Timestamps, checksums, catalog

### Backup Types

| Type | Trigger | Duration | Use Case |
|------|---------|----------|----------|
| **Scheduled** | Cron schedule | Minutes to hours | Routine backups |
| **Manual** | On-demand | Same as scheduled | Immediate backup needs |
| **Continuous WAL** | Automatic | N/A | Enables PITR |

## Backup Configuration

### Environment Configurations

#### Development

```yaml
schedule: "0 3 * * *"  # Daily at 3 AM UTC
retentionPolicy:
  base: 7      # 7 days
  wal: 3       # 3 days
compressionAlgorithm: gzip
endpoint: "minio.minio.svc.cluster.local:9000"
```

#### Staging

```yaml
schedule: "0 2 * * *"  # Daily at 2 AM UTC
retentionPolicy:
  base: 14     # 14 days
  wal: 7       # 7 days
compressionAlgorithm: zstd
compressionLevel: 3
```

#### Production

```yaml
schedule: "0 2 * * *"  # Daily at 2 AM UTC
retentionPolicy:
  base: 30     # 30 days
  wal: 15      # 15 days
compressionAlgorithm: zstd
compressionLevel: 10
encryptionType: sse-s3    # Server-side encryption
```

### Object Storage Configuration

#### MinIO (Development)

```yaml
endpointURL: "http://minio.minio.svc.cluster.local:9000"
region: "us-east-1"
credentials:
  accessKey: minioadmin
  secretKey: minioadmin
```

#### AWS S3 (Production)

```yaml
region: "us-east-1"
# AWS defaults to S3 endpoint
credentials:
  accessKey: <IAM_ACCESS_KEY>
  secretKey: <IAM_SECRET_KEY>
```

## Manual Backup Procedures

### Quick Backup

```bash
# Create on-demand backup
./scripts/dev/create-backup.sh

# Output:
# Creating manual backup: test-app-postgres-backup-1704326400
# Backup job created: test-app-postgres-backup-1704326400
# Waiting for backup to complete...
# ✓ Backup completed successfully!
```

### Backup with Custom Name

```bash
# Trigger backup with custom name
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: test-app-postgres-backup-before-upgrade
  namespace: default
spec:
  cluster:
    name: test-app-postgres
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
    parameters:
      barmanObjectName: postgres-backup-store
  target: prefer-standby  # Use standby to reduce primary load
EOF

# Monitor
kubectl get backup test-app-postgres-backup-before-upgrade -w
kubectl describe backup test-app-postgres-backup-before-upgrade
```

### Check Backup Status

```bash
# List all backups
./scripts/dev/check-backup-status.sh

# Output:
# === PostgreSQL Scheduled Backups ===
# NAME                           SCHEDULE     CLUSTER         SUSPEND
# test-app-postgres-daily-backup      0 2 * * *    test-app-postgres    False
#
# === PostgreSQL Manual Backups ===
# NAME                                  PHASE       STARTTIME             ENDTIME
# test-app-postgres-backup-1704326400       completed   2024-01-03T16:30:45Z  2024-01-03T16:42:22Z
```

### List Backups in Object Storage

```bash
# List backups in MinIO/S3
./scripts/dev/list-backups.sh

# Or with AWS CLI
aws s3 ls s3://postgres-backups/dev/ --recursive --human-readable

# Output example:
# 2024-01-03 16:42:22      10.5 MiB postgres-backups/dev/base/000000010000000000000001
# 2024-01-03 16:42:22   2.1 GiB postgres-backups/dev/wal/000000010000000000000002
```

## Scheduled Backups

### How Scheduled Backups Work

1. **ScheduledBackup CRD** defines the schedule
2. **CloudNativePG Operator** creates a Backup CRD at scheduled time
3. **Barman Cloud Plugin** executes the backup
4. **Backup completes** and results stored in object storage
5. **Retention policy** automatically removes old backups

### Monitoring Scheduled Backups

```bash
# Check scheduled backup definition
kubectl get schedulebackup -A

# Watch backup execution (as it runs)
watch kubectl get backup -A

# Check next scheduled backup time
kubectl get schedulebackup test-app-postgres-daily-backup -o jsonpath='{.status.lastScheduleTime}'

# List recent backup executions
kubectl get backup --sort-by='.metadata.creationTimestamp' -o wide
```

### Modifying Schedule

```bash
# Change backup time to 1 AM
kubectl patch schedulebackup test-app-postgres-daily-backup \
  -p '{"spec":{"schedule":"0 1 * * *"}}'

# Disable scheduled backups (one-time)
kubectl patch schedulebackup test-app-postgres-daily-backup \
  -p '{"spec":{"suspend":true}}'

# Re-enable
kubectl patch schedulebackup test-app-postgres-daily-backup \
  -p '{"spec":{"suspend":false}}'
```

## Restore Procedures

### Full Restore from Latest Backup

```bash
# Restore to new cluster
./scripts/dev/restore-from-backup.sh

# This creates:
# 1. New cluster: "postgres-restored"
# 2. Uses latest available backup
# 3. Waits for cluster to be healthy (~5-10 minutes)
# 4. Verifies restored data
```

### Restore from Specific Backup

```bash
# Find backup name
kubectl get backup --sort-by='.metadata.creationTimestamp' -o jsonpath='{.items[-3:].metadata.name}'

# Restore from specific backup
./scripts/dev/restore-from-backup.sh \
  -b test-app-postgres-backup-1704326400 \
  -n my-restored-cluster

# Monitor restore progress
kubectl get cluster my-restored-cluster -w
```

### Restore Configuration

The restore creates a new cluster with:

```yaml
bootstrap:
  recovery:
    method: object_store
    object_store:
      name: postgres-backup-store  # Reference to ObjectStore CRD
    backupId: <BACKUP_NAME>  # Specific backup to restore from
```

### Post-Restore Steps

1. **Verify data integrity**:
   ```bash
   kubectl exec -it restored-cluster-1 -- psql -U postgres -d app
   
   # Check table counts
   SELECT COUNT(*) FROM important_table;
   
   # Check data consistency
   SELECT * FROM backup_marker ORDER BY id DESC LIMIT 1;
   ```

2. **Scale cluster** if needed:
   ```bash
   kubectl patch cluster restored-cluster --type='json' \
     -p='[{"op":"replace","path":"/spec/instances","value":3}]'
   ```

3. **Enable backups**:
   ```bash
   # Apply backup schedule to restored cluster
   kubectl apply -f deploy/base/postgres-backup.yaml
   ```

4. **Switch application traffic** (after verification):
   ```bash
   # Update application connection string
   # Or update Kubernetes Service endpoints
   ```

## Point-in-Time Recovery

### PITR Overview

**Point-in-Time Recovery** (PITR) allows restoring database to any moment within WAL retention period:

- **Restore Window**: Latest backup time + WAL retention days
- **Precision**: Second-level granularity
- **Method**: Restore from base backup + replay WAL to target time

### PITR Prerequisites

1. Base backups available (at least one)
2. WAL files archived (not older than retention period)
3. Target recovery time within PITR window

### PITR Procedure

```bash
# Restore to specific point in time
./scripts/dev/restore-from-backup.sh \
  -t "2024-01-03 15:30:00" \
  -n pitr-cluster

# Monitoring
kubectl get cluster pitr-cluster -w

# Verification - query database as of that time
kubectl exec pitr-cluster-1 -- psql -U postgres -d app
SELECT * FROM events WHERE created_at > '2024-01-03 15:30:00';  -- Should be empty
```

### Example Scenarios

#### Before Application Bug

```bash
# Bug introduced at 3:45 PM
# Backup exists from 2:00 AM
# PITR window: 2:00 AM - 2:00 AM (next day) + 14 days WAL

# Restore to 3:44:59 PM (before bug)
./scripts/dev/restore-from-backup.sh -t "2024-01-03 15:44:59" -n pre-bug

# Verify bug not present
kubectl exec pre-bug-1 -- psql -U postgres -d app -c "SELECT * FROM buggy_table;"
```

#### After Accidental Data Deletion

```bash
# Data deleted at 2:30 PM
# Recovery time: 2:29 PM

./scripts/dev/restore-from-backup.sh -t "2024-01-03 14:29:00" -n recovered

# Restore deleted data
kubectl exec recovered-1 -- psql -U postgres -d app -c "SELECT COUNT(*) FROM deleted_table;"
```

## Disaster Recovery

### Complete Cluster Loss

```bash
# 1. Create new cluster namespace
kubectl create namespace postgres-recovery

# 2. Restore from backup in new namespace
./scripts/dev/restore-from-backup.sh \
  -s postgres-recovery \
  -n test-app-postgres \
  -b <latest-backup-name>

# 3. Verify restored cluster
kubectl get cluster -n postgres-recovery

# 4. Restore applications pointing to new location
# Update connection strings or update Service endpoints
```

### Partial Data Loss

```bash
# 1. Create PITR cluster to specific time
./scripts/dev/restore-from-backup.sh \
  -t "2024-01-03 before-bad-update" \
  -n recovered-cluster

# 2. Extract needed data
kubectl exec recovered-cluster-1 -- pg_dump -U postgres -d app -t lost_table \
  > lost_table.sql

# 3. Restore data to production
psql -U postgres -d app < lost_table.sql
```

### Corrupted Index

```bash
# Reindex on restored cluster (without affecting production)
# Create PITR to before corruption occurred

# Or reindex in place (if downtime acceptable):
kubectl exec test-app-postgres-1 -- psql -U postgres -d app -c "REINDEX INDEX CONCURRENTLY idx_name;"
```

## Backup Verification

### Automated Verification

```bash
# CloudNativePG automatically verifies backups:
# 1. Checksum validation after backup completes
# 2. Metadata integrity checks
# 3. Object storage accessibility

# Check for failures
./scripts/dev/check-backup-status.sh | grep -i "failed\|error"
```

### Manual Verification

```bash
# Test restore (create test cluster)
./scripts/dev/restore-from-backup.sh \
  -b test-app-postgres-backup-1704326400 \
  -n test-restore

# Verify data matches expectations
kubectl exec test-restore-1 -- psql -U postgres -d app -c "SELECT COUNT(*) FROM my_table;"

# Compare with production
kubectl exec test-app-postgres-1 -- psql -U postgres -d app -c "SELECT COUNT(*) FROM my_table;"

# If counts match, backup is valid
# Delete test cluster
kubectl delete cluster test-restore
```

### Backup Integrity Checks

```bash
# List backup files with checksums
aws s3 ls s3://postgres-backups/dev/base/ --recursive

# Verify backup metadata
kubectl get backup test-app-postgres-backup-1704326400 -o yaml | grep -E "checksum|phase|size"

# Check WAL file integrity
kubectl exec test-app-postgres-1 -- pg_checkpoints
```

## Troubleshooting

### Backup Hangs

```bash
# Check operator logs
kubectl logs -l app.kubernetes.io/name=cloudnative-pg -n cnpg-system | tail -50

# Check backup pod logs (if exists)
kubectl logs test-app-postgres-backup-pod

# Kill stuck backup (forces retry)
kubectl delete backup test-app-postgres-backup-<name>
```

### Backup Fails with Timeout

```bash
# Increase backup timeout (default 300s per WAL)
# For large databases, increase operator configMap

# Or trigger backup during low-activity period
./scripts/dev/create-backup.sh  # Run during maintenance window
```

### Restore Fails

```bash
# Check cluster logs
kubectl describe cluster restored-cluster

# Check PostgreSQL logs
kubectl logs restored-cluster-1

# Verify backup exists
./scripts/dev/check-backup-status.sh

# Try restoring from different backup
./scripts/dev/restore-from-backup.sh -b <older-backup>
```

### PITR Restores to Wrong Time

```bash
# Verify target time is within PITR window
# PITR window = Latest backup + WAL retention days

# List available backups to check dates
./scripts/dev/check-backup-status.sh

# If target time is outside window, use full restore instead
./scripts/dev/restore-from-backup.sh -b <latest-backup>
```

### Out of Object Storage Space

```bash
# Check storage usage
aws s3 ls s3://postgres-backups/ --summarize --human-readable

# Reduce retention policy
kubectl patch objectstore postgres-backup-store \
  -p '{"spec":{"retentionPolicy":{"base":14,"wal":7}}}'

# Manually delete old backups (use with caution!)
# This is automatic - manual deletion not recommended

# Add more storage to object store
# For MinIO: Expand PVC or add new nodes
```

## Best Practices

1. **Test Restores Regularly**: Monthly restore tests to catch issues early
2. **Document Recovery Procedures**: Keep runbooks updated
3. **Monitor Backup Completion**: Alert on failed backups within 5 minutes
4. **Verify Data Integrity**: Spot-check restored data for accuracy
5. **Plan Capacity**: Backups consume storage - plan accordingly
6. **Secure Credentials**: Use Kubernetes Secrets for S3 credentials
7. **Enable Encryption**: Use SSE-S3 for production backups
8. **Archive Old Backups**: Move old backups to cheaper storage (Glacier, etc.)
9. **Document Retention**: Clearly document why you keep backups for X days
10. **Test Disaster Recovery**: Annually perform full DR test

## Additional Resources

- [CloudNativePG Backup Documentation](https://cloudnative-pg.io/documentation/current/backup_recovery/)
- [Barman Cloud Plugin Guide](https://pgbarman.org/barman-cloud/)
- [PostgreSQL Recovery Documentation](https://www.postgresql.org/docs/current/continuous-archiving.html)
- [Operations Guide](POSTGRES.md)
- [Monitoring Guide](POSTGRES_MONITORING.md)
