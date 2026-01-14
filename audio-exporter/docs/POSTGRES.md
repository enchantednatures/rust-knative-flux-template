# PostgreSQL Operations Guide

Complete guide for deploying, managing, and troubleshooting CloudNativePG PostgreSQL clusters in Kubernetes.

## Table of Contents

1. [Quick Start](#quick-start)
2. [Deployment](#deployment)
3. [Configuration](#configuration)
4. [Operations](#operations)
5. [Troubleshooting](#troubleshooting)
6. [Advanced Topics](#advanced-topics)
7. [Best Practices](#best-practices)

## Quick Start

### 1. Deploy PostgreSQL Cluster

```bash
# Deploy with dev configuration (1 instance, MinIO backups)
make dev-up

# Or manually
export KUBECONFIG=.kubeconfig-dev
kubectl apply -k deploy/overlays/dev/

# Wait for cluster to be ready (~2 minutes)
./scripts/dev/check-postgres-status.sh
```

### 2. Connect to PostgreSQL

```bash
# Port-forward from local machine
./scripts/dev/port-forward-postgres.sh

# Connect with psql
psql postgresql://app:PASSWORD@localhost:5432/app

# Or via kubectl
kubectl exec -it audio-exporter-postgres-1 -- psql -U app -d app
```

### 3. Create a Backup

```bash
# Trigger manual backup
./scripts/dev/create-backup.sh

# Check backup status
./scripts/dev/check-backup-status.sh
```

### 4. Restore from Backup

```bash
# Restore to specific backup
./scripts/dev/restore-from-backup.sh -b audio-exporter-postgres-backup-1704326400

# Point-in-time restore
./scripts/dev/restore-from-backup.sh -t "2024-01-03 15:30:00"
```

## Deployment

### Prerequisites

- Kubernetes cluster (Kind, EKS, GKE, etc.)
- kubectl configured to access cluster
- StorageClass with PVCs support
- (Optional) Prometheus Operator for monitoring

### Environment Configurations

| Environment | Cluster Size | Replication | Retention | Storage | Backups |
|------------|-------------|-------------|-----------|---------|---------|
| **dev** | 1 instance | async | 7 days | 20Gi | MinIO (gzip) |
| **staging** | 2 instances | async | 14 days | 100Gi | S3 (zstd-3) |
| **production** | 3 instances | quorum | 30 days | 200Gi | S3 (zstd-10, SSE-S3) |

### Deployment Steps

1. **Set up infrastructure** (one-time):
   ```bash
   kubectl apply -k deploy/infrastructure/cloudnative-pg/operator/
   ```

2. **Prepare environment overlay**:
   ```bash
   # Dev (already includes MinIO)
   kubectl apply -k deploy/overlays/dev/
   
   # Staging
   # First create object-storage-secret.yaml from example
   cp deploy/base/object-storage-secret.yaml.example deploy/overlays/staging/
   # Edit with staging credentials
   sops -e -i deploy/overlays/staging/object-storage-secret.yaml
   kubectl apply -k deploy/overlays/staging/
   
   # Production
   # Similar process with production S3 credentials
   ```

3. **Verify deployment**:
   ```bash
   kubectl get cluster audio-exporter-postgres -o wide
   kubectl get pods -l postgresql=audio-exporter-postgres -o wide
   ```

## Configuration

### PostgreSQL Parameters

Core parameters are set in the base cluster manifest:

```yaml
postgresql:
  parameters:
    # Memory settings
    shared_buffers: "2Gi"        # 25% of available memory
    effective_cache_size: "6Gi"  # 75% of available memory
    
    # Connection settings
    max_connections: "300"
    
    # Replication
    synchronous_commit: "remote_apply"  # Production: zero data loss
    synchronous_standby_names: "ANY 1 (*)"
    
    # Monitoring
    log_min_duration_statement: "1000"  # Log queries > 1 second
    shared_preload_libraries: "pg_stat_statements"
```

### Environment-Specific Overrides

Patches in `deploy/overlays/*/` allow environment-specific customization:

- **Dev**: Minimal resources, async replication, single instance
- **Staging**: Moderate resources, async replication, 2 instances
- **Production**: Full resources, quorum replication, 3 instances

### Storage Configuration

By default, clusters use the default StorageClass. For production:

```yaml
storage:
  size: "200Gi"
  storageClass: "fast-ssd"  # Use SSD for production
```

### Resource Limits

```yaml
resources:
  requests:
    cpu: "1"
    memory: "2Gi"
  limits:
    cpu: "2"
    memory: "4Gi"
```

## Operations

### Cluster Status

```bash
# Check cluster status
kubectl get cluster audio-exporter-postgres

# Detailed status
kubectl describe cluster audio-exporter-postgres

# Check instance status
kubectl get pods -l postgresql=audio-exporter-postgres

# Streaming replication status
kubectl exec audio-exporter-postgres-1 -- psql -U postgres -c "SELECT * FROM pg_stat_replication;"
```

### Scaling

```bash
# Scale to 2 instances
kubectl patch cluster audio-exporter-postgres --type='json' -p='[{"op": "replace", "path": "/spec/instances", "value":2}]'

# Verify scaling
kubectl get pods -l postgresql=audio-exporter-postgres --watch
```

### Backup Operations

#### Manual Backup

```bash
# Create on-demand backup
./scripts/dev/create-backup.sh

# Monitor backup progress
./scripts/dev/check-backup-status.sh

# List all backups in object storage
./scripts/dev/list-backups.sh
```

#### Scheduled Backups

Defined in `postgres-backup.yaml`:

```yaml
schedule: "0 2 * * *"  # Daily at 2 AM UTC
target: prefer-standby  # Use standby to reduce primary load
```

Retention policies are defined in ObjectStore CRD:

```yaml
retentionPolicy:
  base: 30     # Keep base backups for 30 days
  wal: 15      # Keep WAL files for 15 days
```

### Restore Operations

#### From Specific Backup

```bash
# Find backup name
./scripts/dev/check-backup-status.sh

# Restore to new cluster
./scripts/dev/restore-from-backup.sh -b <BACKUP_NAME> -n restored-cluster

# Verify restore
kubectl exec restored-cluster-1 -- psql -U postgres -d app -c "SELECT COUNT(*) FROM my_table;"
```

#### Point-in-Time Recovery

```bash
# Restore to specific timestamp
./scripts/dev/restore-from-backup.sh -t "2024-01-03 15:30:00" -n pitr-cluster

# Verification after PITR
kubectl exec pitr-cluster-1 -- psql -U postgres -d app -c "SELECT NOW();"
```

### High Availability

#### Automatic Failover

CloudNativePG automatically promotes standby if primary fails:

1. Primary pod becomes unavailable
2. Operator detects failure (typically < 30 seconds)
3. Standby automatically promoted to primary
4. Applications automatically fail over (within connection timeout)

Monitor failovers:

```bash
# Watch cluster events
kubectl get events -n default --sort-by='.lastTimestamp' | tail -20

# Check cluster logs for failover
kubectl logs audio-exporter-postgres-1 | grep -i "failover\|promote"
```

#### Manual Failover

```bash
# Delete primary pod (forces failover)
kubectl delete pod audio-exporter-postgres-1

# Verify new primary elected
./scripts/dev/check-postgres-status.sh
```

### Monitoring

See [POSTGRES_MONITORING.md](POSTGRES_MONITORING.md) for:

- Metrics collection and PodMonitor configuration
- Alert rules and firing conditions
- Grafana dashboard setup
- Troubleshooting and performance tuning

### Upgrades

#### Minor Version Upgrade (e.g., 16.0 → 16.1)

```bash
# CloudNativePG automatically handles minor version upgrades
# Rolling restarts with no downtime

# Trigger upgrade (optional, automatic on pod restart)
kubectl rollout restart statefulset audio-exporter-postgres
```

#### Major Version Upgrade (e.g., 15 → 16)

```bash
# Requires pg_upgrade or dump/restore
# More complex - beyond scope of this guide

# See CloudNativePG documentation for pg_upgrade approach
```

## Troubleshooting

### Cluster Not Starting

```bash
# Check cluster status
kubectl get cluster audio-exporter-postgres
kubectl describe cluster audio-exporter-postgres

# Check operator logs
kubectl logs -l app.kubernetes.io/name=cloudnative-pg -n cnpg-system -f

# Check pod events
kubectl describe pod audio-exporter-postgres-1

# Check pod logs
kubectl logs audio-exporter-postgres-1
```

### Pod Stuck in Pending

```bash
# Check storage availability
kubectl get pvc

# Check node resources
kubectl top nodes

# Check node availability
kubectl get nodes

# Increase PVC size if needed
kubectl patch pvc audio-exporter-postgres-1 -p '{"spec":{"resources":{"requests":{"storage":"50Gi"}}}}'
```

### High Replication Lag

```bash
# Check replication status
kubectl exec audio-exporter-postgres-1 -- psql -U postgres -c "SELECT * FROM pg_stat_replication;"

# Monitor lag in real-time
watch -n 5 'kubectl exec audio-exporter-postgres-1 -- psql -U postgres -c "SELECT client_addr, write_lag, flush_lag, replay_lag FROM pg_stat_replication;"'

# Causes and solutions:
# - Primary load: Increase primary resources or connection pool
# - Network latency: Check network connectivity between nodes
# - Standby overloaded: Increase standby resources or reduce client connections
# - Large transactions: Monitor with log_min_duration_statement
```

### Backup Failures

```bash
# Check backup status
./scripts/dev/check-backup-status.sh

# Check operator logs for backup errors
kubectl logs -l app.kubernetes.io/name=cloudnative-pg -n cnpg-system | grep -i "backup\|error"

# Check object storage connectivity
# For MinIO:
kubectl exec audio-exporter-postgres-1 -- s3cmd ls s3://postgres-backups/

# Check credentials secret
kubectl get secret object-storage-secret -o jsonpath='{.data}' | base64 -d
```

### Connection Issues

```bash
# Test connectivity from pod
kubectl exec -it audio-exporter-postgres-1 -- psql -U postgres -d postgres -c "SELECT 1;"

# Check service endpoints
kubectl get endpoints audio-exporter-postgres-rw
kubectl get endpoints audio-exporter-postgres-ro

# Port-forward for local testing
./scripts/dev/port-forward-postgres.sh

# Test local connection
psql postgresql://app:PASSWORD@localhost:5432/app
```

### Query Performance

```bash
# Check slow queries (requires log_min_duration_statement < query_time)
kubectl exec audio-exporter-postgres-1 -- psql -U postgres -d app -c "SELECT * FROM pg_stat_statements ORDER BY mean_exec_time DESC LIMIT 10;"

# Check table sizes
kubectl exec audio-exporter-postgres-1 -- psql -U postgres -d app -c "SELECT tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) FROM pg_tables WHERE schemaname='public' ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;"

# Check index usage
kubectl exec audio-exporter-postgres-1 -- psql -U postgres -d app -c "SELECT * FROM pg_stat_user_indexes WHERE idx_scan = 0;"
```

## Advanced Topics

### Connection Pooling with PgBouncer

PgBouncer is optional in the deployment (currently disabled due to CRD size limits). To enable:

```yaml
# In postgres-cluster.yaml
pooler:
  name: pgbouncer
  parameters:
    max_client_conn: "1000"
    default_pool_size: "25"
    min_pool_size: "5"
    pool_mode: "transaction"  # Connection pooling mode
```

### WAL Archiving and Streaming

WAL archiving to S3/MinIO is configured via:

```yaml
plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true
    parameters:
      barmanObjectName: postgres-backup-store
```

Monitor WAL archiving:

```bash
# Check WAL archiving status
kubectl exec audio-exporter-postgres-1 -- psql -U postgres -c "SELECT * FROM pg_stat_archiver;"

# List archived WAL files
aws s3 ls s3://postgres-backups/wal/ --recursive
```

### Binary Replication Slots

For applications needing logical replication:

```bash
# Create replication slot
kubectl exec audio-exporter-postgres-1 -- psql -U postgres -c "SELECT * FROM pg_create_physical_replication_slot('slot_name');"

# Monitor replication slot
kubectl exec audio-exporter-postgres-1 -- psql -U postgres -c "SELECT * FROM pg_stat_replication_slots;"
```

### PITR Window

WAL archiving enables point-in-time recovery to any timestamp within the WAL retention period:

```bash
# Restore to specific timestamp
./scripts/dev/restore-from-backup.sh -t "2024-01-03 15:30:00"

# PITR window = Latest backup time + WAL retention days
```

## Best Practices

### Security

1. **Credentials**: Store passwords in Kubernetes Secrets
   ```bash
   kubectl create secret generic postgres-password --from-literal=password=$RANDOM_PASSWORD
   ```

2. **Network Access**: Use NetworkPolicies to restrict traffic
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: postgres-network-policy
   spec:
     podSelector:
       matchLabels:
         postgresql: audio-exporter-postgres
     policyTypes:
       - Ingress
     ingress:
       - from:
           - podSelector:
               matchLabels:
                 app: my-app
   ```

3. **Encryption**: Enable SSL/TLS for connections
   - Certificates auto-managed by CloudNativePG

4. **Backup Encryption**: Use S3 server-side encryption in production
   ```yaml
   encryptionType: sse-s3
   ```

### Performance

1. **Shared Buffers**: Set to 25% of available memory
2. **Effective Cache Size**: Set to 75% of available memory
3. **Connection Pooling**: Use PgBouncer for high connection counts
4. **Asynchronous Commits**: Safe for most workloads, improves throughput
5. **Monitoring**: Enable `shared_preload_libraries: "pg_stat_statements"`

### Reliability

1. **Backup Retention**: Keep at least 7 days of backups
2. **Test Restores**: Regularly test restore procedures
3. **Monitor Replication**: Alert on > 10 second replication lag
4. **Capacity Planning**: Monitor storage growth and plan accordingly
5. **Documentation**: Document custom configuration and procedures

### Cost Optimization

1. **Asynchronous Replication**: Use in non-critical environments
2. **Smaller Instances**: Use dev/staging overlays for non-production
3. **Compression**: Enable zstd compression for backups (savings: 50-70%)
4. **Tiered Storage**: Archive old backups to cheaper storage
5. **Right-sizing**: Monitor resource usage and adjust requests/limits

## Additional Resources

- [CloudNativePG Documentation](https://cloudnative-pg.io/)
- [PostgreSQL Documentation](https://www.postgresql.org/docs/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [Monitoring Guide](POSTGRES_MONITORING.md)
- [Backup & Restore Guide](POSTGRES_BACKUP_RESTORE.md)

## Support

For issues or questions:

1. Check the [Troubleshooting](#troubleshooting) section
2. Review CloudNativePG operator logs
3. Check PostgreSQL cluster events: `kubectl get events`
4. Consult official documentation
5. Open an issue in the repository
