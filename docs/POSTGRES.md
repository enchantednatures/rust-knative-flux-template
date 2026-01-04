# PostgreSQL Operations Guide

This guide provides comprehensive instructions for deploying, managing, and troubleshooting PostgreSQL clusters using CloudNativePG in Kubernetes environments.

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Deployment](#deployment)
4. [Configuration](#configuration)
5. [Monitoring](#monitoring)
6. [Troubleshooting](#troubleshooting)
7. [Advanced Operations](#advanced-operations)

## Overview

The PostgreSQL feature uses **CloudNativePG Operator** to manage PostgreSQL clusters in Kubernetes with:

- **High Availability**: Multi-replica deployment with automatic failover
- **Automated Backups**: Scheduled backups to S3-compatible object storage
- **Point-in-Time Recovery (PITR)**: Recover to any point in time via WAL archiving
- **Monitoring**: Prometheus metrics and alerts for cluster health
- **Security**: Encryption at rest and in transit, secret management via SOPS

**Key Components**:

- **CloudNativePG Operator 1.28.0**: Kubernetes operator for PostgreSQL management
- **PostgreSQL 16**: Latest stable version
- **Barman Cloud Plugin**: Backup and recovery management
- **Object Storage**: MinIO (dev) or S3 (prod)
- **FluxCD**: GitOps-based deployment and reconciliation

## Architecture

### Cluster Topology

```
PostgreSQL Cluster (replicated)
├─ Primary (1)        # Handles read/write operations
├─ Replica (2+)       # Read replicas, automatic failover candidates
└─ PgBouncer Pooler   # Connection pooling (optional)
```

### Storage

- **Data**: Kubernetes PersistentVolumes (configurable by environment)
- **Backups**: S3-compatible object storage (MinIO/AWS S3)
- **WAL Archiving**: Continuous streaming to object storage

### Network

- **Internal**: Service-based DNS within cluster
- **External**: Port forwarding for local development
- **Security**: RBAC, network policies, TLS for connections

## Deployment

### Prerequisites

- Kubernetes cluster (1.28+)
- `kubectl` configured to access cluster
- For production: S3 credentials and bucket

### Quick Start (Development)

Deploy PostgreSQL cluster to development environment:

```bash
# 1. Install CloudNativePG operator
./scripts/dev/deploy-postgres.sh --install-operator

# 2. Deploy cluster with MinIO backup storage
./scripts/dev/deploy-postgres.sh

# 3. Port-forward for local access
./scripts/dev/port-forward-postgres.sh

# 4. Connect with psql
psql -h localhost -U postgres -d postgres
```

### Environment-Specific Deployment

Deploy to specific environment using overlay:

```bash
# Development (1 replica, 512Mi memory, 20Gi storage)
kubectl apply -k deploy/overlays/dev

# Staging (2 replicas, 1Gi memory, 100Gi storage)
kubectl apply -k deploy/overlays/staging

# Production (3 replicas, 2Gi memory, 200Gi storage)
kubectl apply -k deploy/overlays/prod
```

### Verify Deployment

Check cluster status:

```bash
# View cluster
kubectl get cluster.postgresql.cnpg.io -A

# Check pod status
kubectl get pods -l app.kubernetes.io/name=postgresql

# Detailed cluster info
./scripts/dev/check-postgres-status.sh
```

Expected output:
```
PostgreSQL Cluster: app-postgres
Status: Ready
Primary: app-postgres-1
Replicas: app-postgres-2, app-postgres-3
Replication Lag: 0 (in sync)
```

## Configuration

### Environment Overlays

Configuration varies by environment using Kustomization patches:

#### Development (`deploy/overlays/dev/`)

```yaml
# Cluster patch
replicas: 1
resources:
  requests:
    cpu: 500m
    memory: 512Mi
storage:
  size: 20Gi

# Backup patch
schedule: "0 3 * * *"      # 3 AM daily
retention: 7d              # Keep 7 days
compression: gzip
```

#### Staging (`deploy/overlays/staging/`)

```yaml
# Cluster patch
replicas: 2
resources:
  requests:
    cpu: 750m
    memory: 1Gi
storage:
  size: 100Gi

# Backup patch
schedule: "0 2 * * *"      # 2 AM daily
retention: 14d             # Keep 14 days
compression: zstd          # Better compression
```

#### Production (`deploy/overlays/prod/`)

```yaml
# Cluster patch
replicas: 3
resources:
  requests:
    cpu: 1000m
    memory: 2Gi
storage:
  size: 200Gi

# Backup patch
schedule: "0 2 * * *"      # 2 AM daily
retention: 30d             # Keep 30 days
compression: zstd          # Level 3 compression
encryption: sse-s3         # Server-side encryption
```

### Customizing Configuration

Edit overlay patches to customize:

1. **Resource Requests/Limits**
   - File: `deploy/overlays/[env]/postgres-cluster-patch.yaml.liquid`
   - Keys: `spec.resources.requests`, `spec.resources.limits`

2. **Backup Schedule**
   - File: `deploy/overlays/[env]/postgres-backup-patch.yaml.liquid`
   - Key: `spec.schedule` (cron format)

3. **Storage Size**
   - File: `deploy/overlays/[env]/postgres-cluster-patch.yaml.liquid`
   - Key: `spec.storage.size`

4. **Retention Policy**
   - File: `deploy/overlays/[env]/postgres-backup-patch.yaml.liquid`
   - Key: `spec.retention` (e.g., `30d`, `180d`)

### Secret Management

PostgreSQL requires secrets for:

1. **Object Storage Credentials** (for backups)
2. **SSL Certificates** (optional, for encrypted connections)
3. **Replication Password** (managed by CloudNativePG)

#### Creating Object Storage Secret

```bash
# 1. Create from template
cp deploy/base/object-storage-secret.yaml.example \
   deploy/overlays/dev/object-storage-secret.yaml

# 2. Edit with credentials
nano deploy/overlays/dev/object-storage-secret.yaml

# Example for MinIO (development):
apiVersion: v1
kind: Secret
metadata:
  name: aws-creds
type: Opaque
stringData:
  ACCESS_KEY_ID: minioadmin
  SECRET_ACCESS_KEY: minioadmin
  BUCKET_NAME: postgres-backups
  ENDPOINT_URL: http://minio:9000

# Example for AWS S3 (production):
apiVersion: v1
kind: Secret
metadata:
  name: aws-creds
type: Opaque
stringData:
  ACCESS_KEY_ID: "AKIA..."
  SECRET_ACCESS_KEY: "..."
  BUCKET_NAME: my-postgres-backups
  ENDPOINT_URL: https://s3.us-east-1.amazonaws.com

# 3. Encrypt with SOPS
sops -e -i deploy/overlays/dev/object-storage-secret.yaml

# 4. Add to kustomization
# Uncomment in deploy/overlays/dev/kustomization.yaml:
#   - object-storage-secret.yaml
```

## Connection

### From Within Cluster

**Service DNS**: `app-postgres.default.svc.cluster.local`

```bash
# Using psql
psql -h app-postgres.default.svc.cluster.local -U postgres -d postgres

# From pod
kubectl exec -it app-postgres-1 -- psql -U postgres -d postgres
```

**Connection String**:
```
postgresql://postgres:password@app-postgres.default.svc.cluster.local:5432/postgres
```

### From Local Machine

Use port-forward:

```bash
# 1. Start port-forward in background
./scripts/dev/port-forward-postgres.sh &

# 2. Connect locally
psql -h localhost -U postgres -d postgres

# 3. Stop port-forward
killall kubectl
```

### From Application

Update application config to connect to PostgreSQL:

```toml
# config.toml
[database]
url = "postgresql://postgres:{{ postgres_password }}@{{ postgres_host }}:5432/{{ postgres_db }}"
min_connections = 5
max_connections = 20
connection_timeout_secs = 30
```

Environment variables override TOML:

```bash
export APP__DATABASE__URL="postgresql://..."
export APP__DATABASE__MAX_CONNECTIONS=50
```

## Monitoring

See [POSTGRES_MONITORING.md](POSTGRES_MONITORING.md) for detailed monitoring setup and dashboards.

### Quick Health Check

```bash
# Check cluster status
./scripts/dev/check-postgres-status.sh

# View recent logs
kubectl logs -l app.kubernetes.io/name=postgresql --tail=100

# Monitor metrics (if Prometheus installed)
kubectl port-forward -n monitoring svc/prometheus 9090:9090
# Visit http://localhost:9090 and search: cnpg_pg_*
```

## Troubleshooting

### Cluster Not Ready

**Symptoms**: `Status: Not Ready` or pods in `Pending` state

**Diagnosis**:
```bash
# 1. Check pod events
kubectl describe pod app-postgres-1

# 2. Check logs
kubectl logs app-postgres-1

# 3. Check PVC status
kubectl get pvc -l app=app-postgres
```

**Solutions**:
- **Insufficient resources**: Increase node capacity or adjust resource requests
- **Storage unavailable**: Check PVC and storage class
- **Image pull error**: Verify image availability and credentials

### High Replication Lag

**Symptoms**: `Replication Lag: >10s`

**Causes**:
- Network congestion
- Heavy write load
- Replica node under-resourced
- WAL archiving bottleneck

**Solutions**:
```bash
# 1. Check replica resource usage
kubectl top pod app-postgres-2

# 2. Scale up replica resources
kubectl patch cluster app-postgres --type merge \
  -p '{"spec":{"resources":{"limits":{"memory":"4Gi"}}}}'

# 3. Check WAL archiving
./scripts/dev/check-postgres-status.sh | grep "WAL"
```

### Backup Failures

**Symptoms**: Backup job fails or backup missing from object storage

**Diagnosis**:
```bash
# 1. Check backup job
kubectl get backups -A

# 2. View job logs
kubectl logs job/app-postgres-backup-*

# 3. Verify object storage credentials
kubectl get secret aws-creds -o jsonpath='{.data.ENDPOINT_URL}' | base64 -d
```

**Solutions**:
- **Wrong credentials**: Update secret with correct values
- **Bucket doesn't exist**: Create bucket in object storage
- **Network unreachable**: Check network policies and security groups

### Connection Refused

**Symptoms**: `psql: could not connect to server: Connection refused`

**Diagnosis**:
```bash
# 1. Check service exists
kubectl get svc app-postgres

# 2. Check port-forward (if using)
ps aux | grep "kubectl port-forward"

# 3. Test connectivity from pod
kubectl run -it --rm test --image=postgres:16 --restart=Never -- \
  pg_isready -h app-postgres -p 5432
```

**Solutions**:
- Restart port-forward: `./scripts/dev/port-forward-postgres.sh`
- Verify service DNS: `nslookup app-postgres.default.svc.cluster.local`
- Check network policies: `kubectl get networkpolicies`

## Advanced Operations

### Manual Backup

Create ad-hoc backup outside schedule:

```bash
./scripts/dev/create-backup.sh

# Monitor backup progress
./scripts/dev/check-backup-status.sh
```

### List Available Backups

```bash
./scripts/dev/list-backups.sh
```

### Point-in-Time Recovery (PITR)

Restore cluster to specific point in time:

```bash
./scripts/dev/restore-from-backup.sh --timestamp "2024-01-03 10:30:00"
```

See [POSTGRES_BACKUP_RESTORE.md](POSTGRES_BACKUP_RESTORE.md) for detailed restore procedures.

### Scaling Replicas

Add or remove read replicas:

```bash
# Scale to 2 replicas
kubectl patch cluster app-postgres \
  -p '{"spec":{"instances":2}}' --type merge

# Scale to 5 replicas
kubectl patch cluster app-postgres \
  -p '{"spec":{"instances":5}}' --type merge

# Monitor scaling
kubectl get pods -w
```

### Accessing Primary Directly

```bash
# Get primary pod name
PRIMARY=$(kubectl get cluster app-postgres \
  -o jsonpath='{.status.currentPrimary}')

# Connect to primary
kubectl exec -it ${PRIMARY} -- psql -U postgres -d postgres
```

### Database Maintenance

Perform maintenance operations:

```bash
# Connect to cluster
kubectl exec -it app-postgres-1 -- psql -U postgres

# Inside psql:
-- Vacuum (cleanup dead tuples)
VACUUM ANALYZE;

-- Check table sizes
SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) 
FROM pg_tables 
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;

-- View connections
SELECT pid, usename, application_name, state FROM pg_stat_activity;
```

### Enabling Extensions

Enable PostgreSQL extensions:

```bash
# Connect to cluster
kubectl exec -it app-postgres-1 -- psql -U postgres

# Inside psql:
CREATE EXTENSION pg_stat_statements;
CREATE EXTENSION postgis;
CREATE EXTENSION uuid-ossp;

-- List installed extensions
\dx
```

## Best Practices

### Security

- ✅ Use SOPS for secret encryption in git
- ✅ Require SSL/TLS for connections
- ✅ Use strong passwords (generate with: `openssl rand -base64 32`)
- ✅ Limit database user privileges (principle of least privilege)
- ✅ Regularly rotate credentials (quarterly minimum)

### Performance

- ✅ Monitor replication lag (alert if >10s)
- ✅ Size resources based on workload (start 512Mi, scale up)
- ✅ Use PgBouncer for connection pooling (with many connections)
- ✅ Enable pg_stat_statements to identify slow queries
- ✅ Archive WAL files to object storage (enable by default)

### Reliability

- ✅ Keep backups at least 2 weeks (30 days recommended)
- ✅ Test restore procedures monthly
- ✅ Monitor backup completion (alert if backup fails)
- ✅ Verify backup integrity (checksums, size validation)
- ✅ Document recovery procedures and recovery time objectives (RTO/RPO)

### Operations

- ✅ Use environment overlays for dev/staging/prod separation
- ✅ Deploy via FluxCD for GitOps (not imperative kubectl apply)
- ✅ Implement namespace-level RBAC for team access
- ✅ Document cluster layout (who owns which databases)
- ✅ Review logs regularly for warnings and errors

## Related Documentation

- [POSTGRES_BACKUP_RESTORE.md](POSTGRES_BACKUP_RESTORE.md) - Backup and restore procedures
- [POSTGRES_MONITORING.md](POSTGRES_MONITORING.md) - Monitoring and alerting setup
- [POSTGRES_FLUXCD.md](POSTGRES_FLUXCD.md) - GitOps integration with FluxCD
- [CloudNativePG Documentation](https://cloudnative-pg.io/documentation/)
- [PostgreSQL Manual](https://www.postgresql.org/docs/)

## Support

For issues or questions:

1. Check [Troubleshooting](#troubleshooting) section
2. Review operator logs: `kubectl logs -n cnpg-system deployment/cnpg-controller-manager`
3. Check cluster events: `kubectl describe cluster app-postgres`
4. Review GitHub issues: https://github.com/cloudnative-pg/cloudnative-pg/issues
