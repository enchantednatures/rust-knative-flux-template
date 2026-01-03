# PostgreSQL Backup and Restore Guide

Comprehensive guide for managing PostgreSQL backups and recovery operations using CloudNativePG's Barman integration.

## Table of Contents

1. [Backup Overview](#backup-overview)
2. [Backup Configuration](#backup-configuration)
3. [Scheduled Backups](#scheduled-backups)
4. [Manual Backups](#manual-backups)
5. [Backup Verification](#backup-verification)
6. [Restore Operations](#restore-operations)
7. [Point-in-Time Recovery (PITR)](#point-in-time-recovery-pitr)
8. [Disaster Recovery](#disaster-recovery)
9. [Backup Troubleshooting](#backup-troubleshooting)

## Backup Overview

### Backup Strategy

CloudNativePG uses **Barman Cloud Plugin** for backup management:

```
PostgreSQL Cluster
    ↓
Continuous WAL Archiving (5-minute intervals)
    ↓
Scheduled Full Backups (daily)
    ↓
Object Storage (S3/MinIO)
```

**Key Features**:
- ✅ **Continuous WAL Archiving**: Every 5 minutes, ensuring minimal data loss
- ✅ **Full Backups**: Daily backups of entire database cluster
- ✅ **Compression**: Zstandard (zstd) compression reduces storage by 70-80%
- ✅ **Retention**: Automated cleanup of old backups (configurable)
- ✅ **Encryption**: Optional server-side encryption for S3 backups
- ✅ **Verification**: Automatic integrity checks via checksums

### Backup Components

1. **ScheduledBackup CRD**: Defines backup schedule and retention
2. **Barman Cloud Plugin**: Handles backup creation and upload
3. **Object Storage**: MinIO (dev) or AWS S3 (prod)
4. **WAL Archiving**: Continuous transaction log streaming

### Backup Frequency & Retention

| Environment | Schedule | Retention | Size Estimate |
|------------|----------|-----------|----------------|
| **Development** | Daily @ 3 AM | 7 days | ~500 MB/day |
| **Staging** | Daily @ 2 AM | 14 days | ~2 GB/day |
| **Production** | Daily @ 2 AM | 30 days | ~10 GB/day |

## Backup Configuration

### Default Configuration (Base)

**File**: `deploy/base/postgres-backup.yaml.liquid`

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: {{ project_name }}-backup
spec:
  schedule: "0 2 * * *"              # 2 AM UTC daily
  cluster:
    name: {{ project_name }}-postgres
  backupOwnerReference: self          # Cleanup with cluster
  compression: zstd                   # zstd compression
  retentionPolicy: "30d"              # Keep 30 days
  target: primary                     # Backup from primary
  immediate: true                     # Backup on creation
```

### Environment-Specific Configuration

Edit overlay patches to customize per environment:

#### Development Backup Patch

**File**: `deploy/overlays/dev/postgres-backup-patch.yaml.liquid`

```yaml
spec:
  schedule: "0 3 * * *"      # 3 AM daily (after primary backup)
  retentionPolicy: "7d"      # Keep only 7 days (save space)
  compression: gzip          # Faster compression
```

#### Staging Backup Patch

**File**: `deploy/overlays/staging/postgres-backup-patch.yaml.liquid`

```yaml
spec:
  schedule: "0 2 * * *"      # 2 AM daily
  retentionPolicy: "14d"     # Keep 14 days
  compression: zstd          # Better compression
```

#### Production Backup Patch

**File**: `deploy/overlays/prod/postgres-backup-patch.yaml.liquid`

```yaml
spec:
  schedule: "0 2 * * *"      # 2 AM daily
  retentionPolicy: "30d"     # Keep 30 days
  compression: zstd          # Maximum compression
  barmanObjectStoreConfig:
    s3Credentials:
      accessKeyId:
        name: aws-creds
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: aws-creds
        key: SECRET_ACCESS_KEY
    endpointURL: https://s3.us-east-1.amazonaws.com
    s3Bucket: my-postgres-backups
    sse: AES256              # Server-side encryption
```

### Customizing Backup Settings

#### Change Backup Schedule

```bash
# Edit the patch file
nano deploy/overlays/prod/postgres-backup-patch.yaml.liquid

# Change schedule to 1 AM
spec:
  schedule: "0 1 * * *"

# Apply changes
kubectl apply -k deploy/overlays/prod
```

**Schedule Format** (cron): `minute hour day month weekday`

Examples:
- `0 2 * * *` → Every day at 2 AM
- `0 3 * * 0` → Sundays at 3 AM (full weekly backup)
- `0 */4 * * *` → Every 4 hours
- `0 2 1 * *` → First day of month at 2 AM (monthly)

#### Change Retention Policy

```bash
# Keep only 7 days
spec:
  retentionPolicy: "7d"

# Keep 60 days
spec:
  retentionPolicy: "60d"

# Keep only 5 backups (regardless of age)
spec:
  retentionPolicy: "5 backups"
```

#### Enable Encryption (Production Only)

```bash
spec:
  barmanObjectStoreConfig:
    s3Credentials: {...}
    sse: AES256              # Enable server-side encryption
```

## Scheduled Backups

### How Scheduled Backups Work

1. **CloudNativePG Controller** watches ScheduledBackup CRD
2. **At scheduled time**: Triggers Barman backup job
3. **Barman** creates full backup of entire cluster
4. **Upload**: Backup compressed and uploaded to object storage
5. **Retention**: Old backups automatically deleted after retention period
6. **Metrics**: Backup metrics recorded in Prometheus

### Monitoring Scheduled Backups

#### Check Next Scheduled Backup

```bash
kubectl get scheduledbacked

# Output:
NAME            SCHEDULE      SUSPEND   AGE
app-postgres    0 2 * * *     false     15d

# View details
kubectl describe scheduledbacked app-postgres
```

#### View Backup History

```bash
./scripts/dev/check-backup-status.sh
```

Expected output:
```
PostgreSQL Cluster: app-postgres
Current Backups:
  Backup: app-postgres-20240103-1
  Status: Succeeded
  Size: 2.5 GB
  Duration: 12 minutes
  Timestamp: 2024-01-03 02:00:00 UTC
  
Previous Backups (last 5):
  - app-postgres-20240102-1 (Success, 2.4 GB, 2024-01-02)
  - app-postgres-20240101-1 (Success, 2.3 GB, 2024-01-01)
  - app-postgres-20231231-1 (Success, 2.6 GB, 2023-12-31)
```

#### View Backups in Object Storage

```bash
./scripts/dev/list-backups.sh
```

Expected output:
```
Backups in Object Storage (MinIO):
  postgres-backups/app-postgres/20240103-020000-1 (2.5 GB)
  postgres-backups/app-postgres/20240102-020000-1 (2.4 GB)
  postgres-backups/app-postgres/20240101-020000-1 (2.3 GB)
  
Total: 7.2 GB (3 backups)
Oldest: 2024-01-01 02:00:00
Latest: 2024-01-03 02:00:00
```

## Manual Backups

### Trigger Manual Backup

Create ad-hoc backup outside regular schedule:

```bash
./scripts/dev/create-backup.sh
```

Script automatically:
1. Creates Backup CRD with unique timestamp
2. Waits for backup to complete (<10 minutes typical)
3. Verifies backup in object storage
4. Checks backup integrity (checksum validation)

### Monitor Manual Backup Progress

```bash
# Watch backup progress
kubectl get backup -w

# View backup logs
kubectl logs -f job/app-postgres-backup-*

# Check final status
./scripts/dev/check-backup-status.sh
```

### Script: create-backup.sh

Located at: `scripts/dev/create-backup.sh`

**Usage**:
```bash
./scripts/dev/create-backup.sh [OPTIONS]

Options:
  --cluster=NAME     PostgreSQL cluster name (default: app-postgres)
  --namespace=NS     Kubernetes namespace (default: default)
  --wait             Wait for backup completion (default: true)
  --timeout=SECS     Max wait time in seconds (default: 600)
```

**Example**:
```bash
# Create and wait for backup
./scripts/dev/create-backup.sh --wait --timeout=900

# Create without waiting
./scripts/dev/create-backup.sh --wait=false
```

## Backup Verification

### Verify Backup Integrity

```bash
# Automated verification (part of create-backup.sh)
./scripts/dev/create-backup.sh

# Manual verification
kubectl get backup app-postgres-20240103-1 \
  -o jsonpath='{.status.phase}' 

# Should output: "completed"
```

### Check Backup Checksum

```bash
# List backups with checksums
kubectl get backup -o wide

# Example output:
NAME                      BACKUP-ID     PHASE          CHECKSUM
app-postgres-20240103-1   1...          completed      c7f...
```

### Verify Backup Accessibility

```bash
# Try restore from backup (dry-run)
./scripts/dev/restore-from-backup.sh \
  --backup-id=app-postgres-20240103-1 \
  --dry-run
```

## Restore Operations

### Full Cluster Restore

Restore entire database cluster from backup:

```bash
# 1. List available backups
./scripts/dev/list-backups.sh

# 2. Restore from latest backup
./scripts/dev/restore-from-backup.sh

# 3. Monitor restore progress
kubectl get cluster app-postgres-restore -w

# 4. Verify restore completed
kubectl get pods -l postgresql-restore=true
```

### Restore to New Cluster Name

```bash
# Restore to new cluster with different name
./scripts/dev/restore-from-backup.sh \
  --backup-id=app-postgres-20240103-1 \
  --target-cluster=app-postgres-restored

# Connect to restored cluster
psql -h app-postgres-restored.default.svc.cluster.local -U postgres
```

### Step-by-Step Restore Procedure

#### 1. Verify Backup Exists

```bash
./scripts/dev/list-backups.sh | grep "20240103"
# Should show: postgres-backups/app-postgres/20240103-020000-1 (2.5 GB)
```

#### 2. Create Restore Cluster Manifest

```bash
# Script automatically creates manifest
./scripts/dev/restore-from-backup.sh

# Or manually create (see template below)
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: app-postgres-restore
spec:
  instances: 3
  postgresql:
    parameters:
      max_connections: "200"
  bootstrap:
    recovery:
      source: clusterBackupObjectStoreConfig
      recoveryTarget:
        # Restore to specific point in time (optional)
        # timeline: "1"
        # xid: "123456789"
      sourceClusterExternalSnapshotRecoveryTarget:
        snapshotName: app-postgres-backup-20240103
        namespaceMapping:
          source: default
          target: default
  externalClusters:
    - name: clusterBackupObjectStoreConfig
      barmanObjectStoreConfig:
        destinationDirectoryWAL: wal_archive
        s3Credentials:
          accessKeyId:
            name: aws-creds
            key: ACCESS_KEY_ID
          secretAccessKey:
            name: aws-creds
            key: SECRET_ACCESS_KEY
        endpointURL: http://minio:9000
        s3Bucket: postgres-backups
        wal_restore_command: 'barman-cloud-wal-restore ...'
  storage:
    size: 100Gi
EOF
```

#### 3. Monitor Restore Progress

```bash
# Watch pod creation
kubectl get pods -w -l postgresql=app-postgres-restore

# View restore logs
kubectl logs app-postgres-restore-1

# Check restore phase
kubectl get cluster app-postgres-restore -o jsonpath='{.status.phase}'
```

#### 4. Verify Restored Data

```bash
# Connect to restored cluster
psql -h app-postgres-restore.default.svc.cluster.local -U postgres

# Inside psql:
-- Check database size
SELECT pg_size_pretty(pg_database_size('postgres'));

-- Check table count
SELECT count(*) FROM information_schema.tables 
WHERE table_schema = 'public';

-- Verify data integrity
SELECT count(*) FROM your_table;
```

#### 5. Optional: Promote Restore Cluster to Primary

After verification, if you want to use restored cluster as new primary:

```bash
# 1. Update application connection string
kubectl set env deployment/app \
  DATABASE_URL="postgresql://postgres:...@app-postgres-restore:5432/postgres"

# 2. Delete old cluster
kubectl delete cluster app-postgres

# 3. Rename restored cluster
kubectl patch cluster app-postgres-restore \
  -p '{"metadata":{"name":"app-postgres"}}'
```

## Point-in-Time Recovery (PITR)

### PITR Overview

Restore database to exact point in time using archived WAL files:

```
Backup (2024-01-03 02:00)
    ↓
WAL Archive (5-minute intervals)
    ↓
Restore to timestamp (2024-01-03 14:30:45)
```

### Requirements for PITR

- ✅ Backup from before target time
- ✅ WAL archives from before target time
- ✅ WAL archiving enabled (enabled by default)
- ✅ Target time within retention window (30 days typical)

### Perform PITR

#### Method 1: Using Script

```bash
# Restore to specific timestamp
./scripts/dev/restore-from-backup.sh \
  --timestamp="2024-01-03 14:30:45" \
  --target-cluster=app-postgres-pitr

# Wait for restore to complete
kubectl get cluster app-postgres-pitr -w

# Verify data as of that time
psql -h app-postgres-pitr.default.svc.cluster.local -U postgres
```

#### Method 2: Manual PITR Manifest

```bash
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: app-postgres-pitr
spec:
  instances: 1
  bootstrap:
    recovery:
      source: clusterBackupObjectStoreConfig
      recoveryTarget:
        # Restore to this timestamp
        targetTime: "2024-01-03T14:30:45Z"
        # Use immediate (without archive recovery)
        # timeline: "1"
  externalClusters:
    - name: clusterBackupObjectStoreConfig
      barmanObjectStoreConfig:
        # ... (same as full restore above)
EOF
```

### PITR Examples

#### Recover to Morning Before Data Loss

```bash
# Data loss occurred at 9:30 AM
# Recover to 9:00 AM same day

./scripts/dev/restore-from-backup.sh \
  --timestamp="2024-01-03 09:00:00" \
  --target-cluster=app-postgres-recovered
```

#### Recover to Yesterday Midnight

```bash
# Recover to start of yesterday
./scripts/dev/restore-from-backup.sh \
  --timestamp="2024-01-02 00:00:00" \
  --target-cluster=app-postgres-yesterday
```

#### Find Deletion Timestamp

```bash
# If you don't know exact time:
# 1. Check application logs for error time
# 2. Check PostgreSQL logs for drop table command
# 3. Use timestamp 1 minute before deletion occurred

./scripts/dev/restore-from-backup.sh \
  --timestamp="2024-01-03 15:29:00" \
  --target-cluster=app-postgres-before-delete
```

## Disaster Recovery

### Disaster Recovery Plan

**Scenario**: Primary node failure with data corruption

**Recovery Steps**:

1. **Assessment** (~5 minutes)
   ```bash
   ./scripts/dev/check-postgres-status.sh
   # Confirm cluster unhealthy
   ```

2. **Backup Verification** (~5 minutes)
   ```bash
   ./scripts/dev/list-backups.sh
   # Verify recent backup exists
   ```

3. **Restore Cluster** (~15 minutes)
   ```bash
   ./scripts/dev/restore-from-backup.sh \
     --backup-id=app-postgres-20240103-1 \
     --target-cluster=app-postgres-recovered
   # Monitor: kubectl get pods -w
   ```

4. **Data Verification** (~5 minutes)
   ```bash
   # Verify data integrity
   psql -h app-postgres-recovered -U postgres -c \
     "SELECT count(*) FROM your_critical_table;"
   ```

5. **Cutover** (~10 minutes)
   ```bash
   # Update connection strings to restored cluster
   kubectl set env deployment/app \
     DATABASE_URL="postgresql://...@app-postgres-recovered:5432/postgres"
   # Verify application connects successfully
   ```

**Total RTO (Recovery Time Objective)**: ~40 minutes  
**RPO (Recovery Point Objective)**: ~5 minutes (latest WAL archive)

### Backup Strategy for Compliance

#### Financial Services (99.99% uptime requirement)

```yaml
# Backup configuration
schedule: "0 * * * *"          # Every hour
retentionPolicy: "90d"         # 3 months
compression: zstd
target: primary
redundancy: 3                  # Multiple storage locations
```

#### Healthcare (HIPAA compliant)

```yaml
schedule: "0 2,14 * * *"       # Twice daily (2 AM, 2 PM)
retentionPolicy: "365d"        # 1 year
compression: zstd
encryption: AES256             # Server-side encryption
audit: enabled                 # Log all backup operations
```

#### Development/Testing

```yaml
schedule: "0 3 * * *"          # Daily @ 3 AM
retentionPolicy: "7d"          # 1 week
compression: gzip              # Faster compression
target: primary
```

### Testing Disaster Recovery

**Recommended**: Test restore monthly

```bash
# 1. Create test restore cluster
./scripts/dev/restore-from-backup.sh \
  --target-cluster=app-postgres-test \
  --verbose

# 2. Run integrity checks
psql -h app-postgres-test -U postgres <<EOF
-- Table counts match
SELECT count(*) FROM your_table;

-- Indexes exist
\di

-- Constraints intact
\d your_table

-- Data types correct
SELECT column_name, data_type FROM information_schema.columns 
WHERE table_name='your_table';
EOF

# 3. Run application test suite
kubectl run -it --rm test-app \
  --image=your-app:test \
  --env=DATABASE_URL=postgresql://...@app-postgres-test:5432/postgres \
  -- pytest

# 4. Clean up test cluster
kubectl delete cluster app-postgres-test
```

## Backup Troubleshooting

### Backup Failed

**Symptoms**: Backup stuck in pending or failed status

**Diagnosis**:
```bash
# 1. Check ScheduledBackup status
kubectl get scheduledbacked -o wide

# 2. View event logs
kubectl describe scheduledbacked app-postgres

# 3. Check operator logs
kubectl logs -n cnpg-system deployment/cnpg-controller-manager | grep backup

# 4. Check if backup job exists
kubectl get jobs | grep backup
```

**Common Causes & Solutions**:

| Cause | Symptom | Solution |
|-------|---------|----------|
| Wrong S3 credentials | Auth error | Update secret: `kubectl edit secret aws-creds` |
| Bucket doesn't exist | 404 error | Create bucket in MinIO/S3 |
| Network blocked | Connection timeout | Check network policies, security groups |
| Insufficient disk | Disk full | Delete old backups or increase storage |
| Operator not ready | Job stuck pending | Wait for operator, check: `kubectl get deployment -n cnpg-system` |

### Backup Taking Too Long

**Symptoms**: Backup > 30 minutes for database expected to backup in < 10 minutes

**Investigation**:
```bash
# Check backup job CPU/memory
kubectl top pod app-postgres-backup-*

# Check network throughput
kubectl exec app-postgres-1 -- nstat | grep -i "tcp"

# Check object storage performance
./scripts/dev/check-backup-status.sh
```

**Solutions**:
- Increase object storage bandwidth (AWS S3 region closer to cluster)
- Decrease backup compression level (edit patch `compression: gzip`)
- Scale up barman pod resources (edit ScheduledBackup)

### Backup Missing from Object Storage

**Symptoms**: Backup reports "Succeeded" but file not in MinIO/S3

**Diagnosis**:
```bash
# 1. Verify backup CRD exists
kubectl get backup | grep "20240103"

# 2. Check backup CRD details
kubectl describe backup app-postgres-20240103-1

# 3. List files in storage
./scripts/dev/list-backups.sh

# 4. Check barman logs
kubectl logs -l app=barman --all-containers=true
```

**Solutions**:
- Verify object storage credentials
- Check network connectivity to object storage
- Review barman logs for upload failures
- Increase backup timeout if storage is slow

### WAL Archiving Not Working

**Symptoms**: 
- Backup status shows "WAL archiving failed"
- Cannot restore to timestamp

**Diagnosis**:
```bash
# Check WAL archiving configuration
kubectl get cluster app-postgres -o jsonpath='{.spec.postgresql.parameters.archive_command}'

# View WAL archiving logs
kubectl logs app-postgres-1 | grep -i "archive"

# Check WAL files in object storage
aws s3 ls s3://postgres-backups/app-postgres/wal/
```

**Solutions**:
- Verify object storage credentials are accessible from pod
- Check network policies don't block access to object storage
- Review barman cloud configuration in cluster manifest

### Old Backups Not Being Deleted

**Symptoms**: Retention policy not enforced, old backups still present

**Diagnosis**:
```bash
# Check retention policy configured
kubectl get scheduledbacked -o jsonpath='{.spec.retentionPolicy}'

# Check backup ages
./scripts/dev/list-backups.sh | head -10

# View controller logs
kubectl logs -n cnpg-system deployment/cnpg-controller-manager | grep retention
```

**Solutions**:
- Update retention policy: edit `deploy/overlays/ENV/postgres-backup-patch.yaml.liquid`
- Manually delete old backups: `kubectl delete backup app-postgres-20231215-1`
- Restart operator to trigger cleanup: `kubectl rollout restart deployment/cnpg-controller-manager -n cnpg-system`

## Backup Best Practices

✅ **Schedule During Low-Traffic Windows**
- Avoid business hours when possible
- Stagger schedules (primary 2 AM, standby 3 AM)

✅ **Monitor Backup Success Rate**
- Alert if backup fails 2+ times in a row
- Track backup duration trends (anomaly detection)
- Validate backup size (detect if undersized)

✅ **Test Restores Regularly**
- Monthly restore tests (minimum)
- Document PITR scenarios
- Validate data integrity post-restore

✅ **Maintain Backup Inventory**
- Keep backup manifest in git
- Document backup schedule and retention
- Track object storage costs

✅ **Secure Backups**
- Enable encryption for production
- Limit backup access via IAM policies
- Audit backup operations

✅ **Document Recovery Procedures**
- Write runbooks for different failure scenarios
- Document RTO/RPO for each environment
- Include contact escalation procedures

## References

- [CloudNativePG Backup Documentation](https://cloudnative-pg.io/documentation/current/backup_recovery/)
- [Barman Cloud Documentation](https://docs.pgbarman.org/release/barman-cloud/)
- [PostgreSQL WAL Archiving](https://www.postgresql.org/docs/current/wal-archiving.html)
