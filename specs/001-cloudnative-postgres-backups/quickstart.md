# Quickstart: CloudNative PostgreSQL with Automated Backups

This guide walks you through deploying a PostgreSQL cluster with automated backups using CloudNativePG operator and Barman Cloud Plugin.

## Prerequisites

Before starting, ensure the following are installed in your Kubernetes cluster:

1. **CloudNativePG Operator** (v1.26+)
   ```bash
   kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.28/releases/cnpg-1.28.0.yaml
   ```

2. **Barman Cloud Plugin** (v1.3+)
   ```bash
   kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/plugin-barman-cloud/v1.3.0/releases/plugin-barman-cloud-1.3.0.yaml
   ```

3. **Object Storage** (one of):
   - MinIO (development/staging) - see `scripts/dev/deploy-infrastructure.sh`
   - AWS S3 (production)
   - S3-compatible storage (Ceph RGW, etc.)

4. **Storage Credentials** (Kubernetes Secret)
   ```bash
   kubectl create secret generic minio-credentials \
     --from-literal=ACCESS_KEY_ID=minioadmin \
     --from-literal=ACCESS_SECRET_KEY=minioadmin
   ```

5. **kubectl** configured with cluster access
6. **Kubernetes cluster** with at least 2 CPU and 4GB memory available

**Verification**:
```bash
# Check operator is running
kubectl get pods -n cnpg-system

# Check plugin is installed
kubectl get deployment -n cnpg-system plugin-barman-cloud
```

---

## 1. Deploy PostgreSQL Cluster (5 minutes)

### Step 1.1: Create ObjectStore Configuration

This configures where backups will be stored and how they'll be compressed.

```bash
kubectl apply -f - <<EOF
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: minio-dev
  namespace: default
spec:
  configuration:
    destinationPath: s3://postgres-backups/
    endpointURL: http://minio:9000
    s3Credentials:
      accessKeyId:
        name: minio-credentials
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: minio-credentials
        key: ACCESS_SECRET_KEY
    data:
      compression: gzip
      jobs: 2
    wal:
      compression: gzip
      maxParallel: 4
  retentionPolicy: "7d"
EOF
```

**What this does**:
- Creates `ObjectStore` resource pointing to MinIO
- Configures gzip compression for backups
- Sets 7-day retention policy (backups older than 7 days are auto-deleted)

### Step 1.2: Deploy PostgreSQL Cluster

```bash
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-app
  namespace: default
spec:
  instances: 3
  
  postgresql:
    version: "16"
    parameters:
      shared_buffers: "512MB"
      max_connections: "300"
      synchronous_commit: "remote_apply"
      synchronous_standby_names: "ANY 1 (*)"
      archive_timeout: "5min"
      wal_compression: "on"
    shared_preload_libraries:
      - "pg_stat_statements"
  
  resources:
    requests:
      cpu: "1"
      memory: "2Gi"
    limits:
      cpu: "2"
      memory: "4Gi"
  
  storage:
    size: "20Gi"
  
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: minio-dev
  
  bootstrap:
    initdb:
      postInitApplicationSQL:
        - "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
EOF
```

**What this does**:
- Creates 3-replica PostgreSQL cluster (1 primary + 2 standby)
- Enables automatic WAL archiving to MinIO every 5 minutes
- Configures high-availability with quorum replication
- Enables pg_stat_statements extension for query monitoring

### Step 1.3: Verify Cluster is Ready

```bash
# Wait for cluster to become ready (may take 2-5 minutes)
kubectl wait --for=condition=Ready cluster/postgres-app --timeout=5m

# Check cluster status
kubectl get cluster postgres-app

# Check pods are running
kubectl get pods -l cnpg.io/cluster=postgres-app
```

**Expected output**:
```
NAME            AGE     INSTANCES   READY   STATUS
postgres-app    2m30s   3           3       Cluster in healthy state
```

### Step 1.4: Connect to Database

```bash
# Get primary service endpoint
kubectl get service postgres-app-rw

# Connect using psql (from inside cluster)
kubectl exec -it postgres-app-1 -- psql -U postgres

# Or port-forward for local access
kubectl port-forward svc/postgres-app-rw 5432:5432
psql -h localhost -U postgres -d postgres
```

**Connection strings for applications**:
- **Primary (read-write)**: `postgres-app-rw.default.svc.cluster.local:5432`
- **Replicas (read-only)**: `postgres-app-ro.default.svc.cluster.local:5432`

---

## 2. Configure Automated Backups (2 minutes)

### Step 2.1: Create Backup Schedule

```bash
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: postgres-app-daily-backup
  namespace: default
spec:
  schedule: "0 2 * * *"  # Daily at 2:00 AM UTC
  
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
    parameters:
      barmanObjectName: minio-dev
  
  cluster:
    name: postgres-app
  
  immediate: true  # Take first backup immediately
EOF
```

**What this does**:
- Schedules daily backups at 2:00 AM UTC
- Uses Barman Cloud Plugin to upload backups to MinIO
- Takes immediate backup for testing (don't wait until 2 AM)

### Step 2.2: Verify Backup is Running

```bash
# Watch backup progress
kubectl get backups -w

# Check backup details
kubectl describe backup $(kubectl get backups -o name | head -1)
```

**Expected output**:
```
NAME                              AGE   CLUSTER        PHASE       ERROR
postgres-app-daily-backup-xxxxx   30s   postgres-app   running
```

After 1-5 minutes (depending on database size):
```
NAME                              AGE   CLUSTER        PHASE       ERROR
postgres-app-daily-backup-xxxxx   3m    postgres-app   completed
```

### Step 2.3: Verify Backup in Object Storage

```bash
# For MinIO - check backup files exist
kubectl run -it --rm minio-check --image=minio/mc --restart=Never -- sh -c "
  mc alias set minio http://minio:9000 minioadmin minioadmin
  mc ls -r minio/postgres-backups/
"
```

**Expected output** (backup files):
```
[2026-01-03 14:30:00 UTC] base/20260103T143000/backup.info
[2026-01-03 14:30:00 UTC] base/20260103T143000/data.tar.gz
[2026-01-03 14:30:05 UTC] wals/0000000100000000/000000010000000000000001.gz
```

---

## 3. Restore from Backup (10 minutes)

### Step 3.1: Simulate Data Loss

```bash
# Connect to database
kubectl exec -it postgres-app-1 -- psql -U postgres

# Create test data
CREATE TABLE test_data (id SERIAL PRIMARY KEY, value TEXT);
INSERT INTO test_data (value) VALUES ('before backup');
SELECT * FROM test_data;

# Note the current time (you'll restore to this point)
SELECT now();

# Wait 1 minute, then delete data (simulate incident)
-- Wait 60 seconds
DELETE FROM test_data;
SELECT * FROM test_data;  -- Should be empty
```

### Step 3.2: Restore to Point-in-Time

```bash
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-app-restored
  namespace: default
spec:
  instances: 2  # Smaller cluster for restore
  
  postgresql:
    version: "16"
  
  resources:
    requests:
      cpu: "500m"
      memory: "1Gi"
    limits:
      cpu: "1"
      memory: "2Gi"
  
  storage:
    size: "20Gi"
  
  # Bootstrap from backup with PITR
  bootstrap:
    recovery:
      source: postgres-app-backup
      recoveryTarget:
        targetTime: "2026-01-03T14:35:00Z"  # Replace with timestamp from step 3.1
  
  # Reference source backup
  externalClusters:
    - name: postgres-app-backup
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: minio-dev
          serverName: postgres-app  # Original cluster name
EOF
```

**What this does**:
- Creates new cluster `postgres-app-restored` from backup
- Restores to specific timestamp (before data deletion)
- Uses same backup storage (MinIO)

### Step 3.3: Verify Restored Data

```bash
# Wait for restored cluster to be ready
kubectl wait --for=condition=Ready cluster/postgres-app-restored --timeout=10m

# Connect to restored database
kubectl exec -it postgres-app-restored-1 -- psql -U postgres

# Check data is recovered
SELECT * FROM test_data;  -- Should show 'before backup'
```

**Expected output**:
```
 id |     value      
----+----------------
  1 | before backup
(1 row)
```

### Step 3.4: Cleanup Restored Cluster (Optional)

```bash
# After verifying data, delete restored cluster
kubectl delete cluster postgres-app-restored
```

---

## 4. Monitoring and Alerts

### Step 4.1: View Backup Metrics

```bash
# Get cluster status with backup info
kubectl describe cluster postgres-app

# Check recent backups
kubectl get backups -l cnpg.io/cluster=postgres-app

# View scheduled backup status
kubectl describe scheduledbackup postgres-app-daily-backup
```

### Step 4.2: Query Prometheus Metrics (if Prometheus is installed)

```bash
# Port-forward to Prometheus
kubectl port-forward -n monitoring svc/prometheus 9090:9090

# Open http://localhost:9090 and query:
barman_cloud_cloudnative_pg_io_backup_status{cluster="postgres-app"}
barman_cloud_cloudnative_pg_io_last_backup_timestamp{cluster="postgres-app"}
barman_cloud_cloudnative_pg_io_backup_duration_seconds{cluster="postgres-app"}
```

### Step 4.3: Configure Alerts (Optional)

Create PrometheusRule for backup failures:

```bash
kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: postgres-backup-alerts
  namespace: default
spec:
  groups:
    - name: postgres-backups
      interval: 5m
      rules:
        - alert: PostgresBackupFailed
          expr: barman_cloud_cloudnative_pg_io_backup_status == 0
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "PostgreSQL backup failed for {{ \$labels.cluster }}"
            description: "Backup has been failing for 10+ minutes"
        
        - alert: PostgresBackupStale
          expr: time() - barman_cloud_cloudnative_pg_io_last_backup_timestamp > 86400
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: "PostgreSQL backup is stale for {{ \$labels.cluster }}"
            description: "No successful backup in the last 24 hours"
EOF
```

### Step 4.4: View Logs

```bash
# CloudNativePG operator logs
kubectl logs -n cnpg-system deployment/cnpg-controller-manager -f

# Barman Cloud Plugin logs
kubectl logs -n cnpg-system deployment/plugin-barman-cloud -f

# PostgreSQL instance logs
kubectl logs postgres-app-1 -f
```

---

## Common Operations

### Trigger Manual Backup
```bash
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: postgres-app-manual-$(date +%Y%m%d-%H%M%S)
  namespace: default
spec:
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
    parameters:
      barmanObjectName: minio-dev
  cluster:
    name: postgres-app
EOF
```

### Pause Scheduled Backups
```bash
kubectl patch scheduledbackup postgres-app-daily-backup \
  --type=merge -p '{"spec":{"suspend":true}}'
```

### Resume Scheduled Backups
```bash
kubectl patch scheduledbackup postgres-app-daily-backup \
  --type=merge -p '{"spec":{"suspend":false}}'
```

### Change Backup Schedule
```bash
kubectl patch scheduledbackup postgres-app-daily-backup \
  --type=merge -p '{"spec":{"schedule":"0 */6 * * *"}}'  # Every 6 hours
```

### View Backup Storage Usage
```bash
# For MinIO
kubectl run -it --rm minio-check --image=minio/mc --restart=Never -- sh -c "
  mc alias set minio http://minio:9000 minioadmin minioadmin
  mc du minio/postgres-backups/
"
```

### List Available Backups
```bash
kubectl get backups -l cnpg.io/cluster=postgres-app \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,SIZE:.status.size,STARTED:.status.startedAt
```

### Delete Old Manual Backups
```bash
# Delete backups older than 7 days (scheduled backups are auto-cleaned)
kubectl get backups -o json | jq -r '
  .items[] |
  select(.status.startedAt != null) |
  select(.status.startedAt | fromdateiso8601 < (now - 604800)) |
  .metadata.name
' | xargs -I {} kubectl delete backup {}
```

---

## Troubleshooting

### Backup Stuck in "pending" or "running"
```bash
# Check cluster health
kubectl get cluster postgres-app

# Check backup details
kubectl describe backup <backup-name>

# Check operator logs
kubectl logs -n cnpg-system deployment/cnpg-controller-manager --tail=100

# Common fixes:
# - Ensure ObjectStore CRD exists and is valid
# - Verify S3 credentials are correct
# - Check network connectivity to object storage
```

### Restore Failed
```bash
# Check restore cluster status
kubectl describe cluster postgres-app-restored

# Common issues:
# - Invalid timestamp format (must be RFC 3339: 2026-01-03T14:30:00Z)
# - Source backup doesn't exist or is incomplete
# - Insufficient storage for restore
# - WAL files missing for PITR window
```

### WAL Archiving Not Working
```bash
# Check cluster has plugin configured
kubectl get cluster postgres-app -o jsonpath='{.spec.plugins}'

# Should show:
# [{"isWALArchiver":true,"name":"barman-cloud.cloudnative-pg.io","parameters":{"barmanObjectName":"minio-dev"}}]

# Check plugin logs
kubectl logs -n cnpg-system deployment/plugin-barman-cloud --tail=50

# Verify ObjectStore is accessible
kubectl describe objectstore minio-dev
```

### High Backup Storage Usage
```bash
# Check retention policy
kubectl get objectstore minio-dev -o jsonpath='{.spec.retentionPolicy}'

# Adjust retention (reduce from 7d to 3d)
kubectl patch objectstore minio-dev \
  --type=merge -p '{"spec":{"retentionPolicy":"3d"}}'

# Manually trigger cleanup (backups older than retention policy are deleted)
# This happens automatically but can be forced by creating a new backup
```

---

## Next Steps

1. **Production Configuration**: See `docs/DEPLOYMENT.md` for production hardening:
   - IRSA for AWS S3 access (no static credentials)
   - TLS encryption for PostgreSQL connections
   - Resource limits tuning
   - Multi-AZ deployment

2. **Monitoring Setup**: See `docs/MONITORING.md` for comprehensive observability:
   - Grafana dashboards for backup metrics
   - Alertmanager integration
   - Log aggregation with Loki

3. **High Availability Testing**: See `docs/TESTING.md` for failure scenarios:
   - Node failure simulation
   - Network partition testing
   - Backup restore validation

4. **Backup Strategy**: See `docs/ARCHITECTURE.md` for:
   - RTO/RPO calculation
   - Backup frequency recommendations
   - Retention policy guidelines
   - Cross-region replication

---

## Summary

You have successfully:
✅ Deployed a 3-replica PostgreSQL cluster with CloudNativePG  
✅ Configured automated daily backups to MinIO using Barman Cloud Plugin  
✅ Performed a point-in-time restore from backup  
✅ Set up basic monitoring and alerts  

**Connection Info**:
- **Primary (RW)**: `postgres-app-rw.default.svc.cluster.local:5432`
- **Replicas (RO)**: `postgres-app-ro.default.svc.cluster.local:5432`

**Backup Info**:
- **Schedule**: Daily at 2:00 AM UTC
- **Storage**: MinIO (s3://postgres-backups/)
- **Retention**: 7 days
- **Compression**: gzip

For more information, see:
- `specs/001-cloudnative-postgres-backups/spec.md` - Feature specification
- `specs/001-cloudnative-postgres-backups/contracts/` - CRD schemas and examples
- `docs/POSTGRES*.md` - Detailed documentation (coming soon)
