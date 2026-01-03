# PostgreSQL E2E Test Suite

This directory contains end-to-end tests that validate the complete PostgreSQL deployment, high availability, backup, and restore functionality in Kubernetes using CloudNativePG.

## Overview

The E2E test suite validates:

1. **Cluster Deployment** (08-test-postgres-deployment.sh)
   - PostgreSQL cluster creation and initialization
   - Primary instance election
   - Replica synchronization
   - Service endpoint availability
   - Basic connectivity and data operations

2. **Backup and Restore** (09-test-backup-restore.sh)
   - Backup creation with test data
   - Backup verification in object storage
   - Restore from backup to new cluster
   - Data integrity validation
   - Point-in-time recovery

3. **High Availability & Failover** (10-test-failover.sh)
   - Primary pod failure simulation
   - Automatic failover to replica
   - Failover time measurement (target: <2 minutes)
   - Zero data loss verification
   - Write capability after failover
   - Replication validation

## Test Scripts

### 08-test-postgres-deployment.sh

**Purpose**: Validate cluster deployment and basic operations

**What it tests**:
- Cluster readiness within 5 minutes (SC-001)
- Primary instance election
- Replica instance synchronization
- Service endpoint creation (read-write, read-only)
- Basic CRUD operations
- Data replication

**Duration**: ~5-10 minutes

**Requirements**:
- CloudNativePG operator installed
- test-cluster.yaml fixture exists
- kubectl access with cluster privileges

**Usage**:
```bash
./08-test-postgres-deployment.sh
```

### 09-test-backup-restore.sh

**Purpose**: Validate backup and restore functionality

**What it tests**:
- Creating ~1GB test data
- Triggering full backup with Barman Cloud Plugin
- Backup completion and verification
- Backup metadata in object storage
- Restoring from backup
- Data integrity post-restore
- Point-in-time recovery (PITR)

**Duration**: ~15-20 minutes (depends on data size and storage speed)

**Requirements**:
- CloudNativePG operator with Barman Cloud Plugin
- Object storage (MinIO or S3) configured and accessible
- PostgreSQL backup credentials secret

**Usage**:
```bash
./09-test-backup-restore.sh
```

**Environment Variables**:
- `MINIO_ENDPOINT`: MinIO endpoint (default: http://minio:9000)
- `MINIO_ACCESS_KEY`: MinIO access key (default: minioadmin)
- `MINIO_SECRET_KEY`: MinIO secret key (default: minioadmin)
- `BACKUP_BUCKET`: S3/MinIO bucket (default: postgres-backups)

### 10-test-failover.sh

**Purpose**: Validate high availability and automatic failover

**What it tests**:
- Primary pod deletion simulation
- Automatic primary promotion from replicas
- Failover completion within 2 minutes (SC-003)
- Zero data loss on failover (SC-007)
- Write capability after failover
- Replication status post-failover

**Duration**: ~3-5 minutes

**Requirements**:
- Multi-instance cluster (at least 2 instances)
- 08-test-postgres-deployment.sh must have completed
- Test data in place from deployment test

**Usage**:
```bash
./10-test-failover.sh
```

**Skip conditions**:
- Automatically skipped if cluster has only 1 instance

## Running Tests

### Local Development

#### Prerequisites

```bash
# Install required tools
kind --version          # Create local K8s clusters
kubectl version --client
helm version
flux version

# Ensure Kind cluster is running with CloudNativePG operator
kind create cluster --name postgres-test
kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.28/releases/cnpg-1.28.0.yaml
```

#### Run Individual Tests

```bash
# Test cluster deployment
./08-test-postgres-deployment.sh

# Test backup and restore (requires deployment test first)
./09-test-backup-restore.sh

# Test failover (requires deployment test first)
./10-test-failover.sh
```

#### Run Full Test Suite

```bash
# Run all tests in sequence
bash -x ./08-test-postgres-deployment.sh && \
bash -x ./09-test-backup-restore.sh && \
bash -x ./10-test-failover.sh
```

### CI/CD Pipeline

Tests are integrated into GitHub Actions workflow (see `.github/workflows/`):

```yaml
test-postgres-e2e:
  runs-on: ubuntu-latest
  steps:
    - name: Setup Kind cluster
      run: bash tests/e2e/scripts/00-setup-kind.sh
    
    - name: Install CloudNativePG operator
      run: bash tests/e2e/scripts/07-deploy-postgres.sh
    
    - name: Test deployment
      run: bash tests/e2e/scripts/08-test-postgres-deployment.sh
    
    - name: Test backup/restore
      run: bash tests/e2e/scripts/09-test-backup-restore.sh
    
    - name: Test failover
      run: bash tests/e2e/scripts/10-test-failover.sh
    
    - name: Cleanup
      if: always()
      run: bash tests/e2e/scripts/99-cleanup.sh
```

## Test Fixtures

### test-cluster.yaml
Minimal CloudNativePG cluster for E2E testing:
- 2 instances (1 primary + 1 replica)
- 500m CPU / 512Mi memory requests
- 2Gi storage
- Quorum replication enabled

### test-backup-config.yaml
Backup configuration for E2E testing:
- Daily backup schedule at 2 AM UTC
- 7-day retention policy
- MinIO/S3 integration
- Barman Cloud Plugin

### test-data.sql
SQL script generating ~1GB test data:
- 1M test records with metadata
- JSONB columns
- Indexes for realistic workload
- Backup marker table for verification

## Success Criteria

Each test validates specific success criteria from the specification:

### Deployment Test
- ✅ SC-001: Cluster ready within 5 minutes
- ✅ AC1: Cluster reaches healthy state
- ✅ AC2: Applications can connect and query

### Failover Test
- ✅ SC-003: Cluster recovers from failure within 2 minutes
- ✅ SC-007: Zero data loss during failover
- ✅ AC3: Cluster survives primary pod deletion

### Backup/Restore Test
- ✅ SC-005: Restore completes within 15 minutes for 10GB
- ✅ SC-010: Backups created and managed by policy

## Troubleshooting

### Deployment Test Failures

**Issue**: Cluster fails to become ready
```bash
# Check cluster status
kubectl describe cluster postgres-test -n default

# Check operator logs
kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg

# Check pod status
kubectl get pods -n default -l cnpg.io/cluster=postgres-test
```

**Issue**: Can't connect to database
```bash
# Verify primary pod is running
kubectl get pods -n default -l cnpg.io/cluster=postgres-test,cnpg.io/podRole=primary

# Check pod logs
kubectl logs -n default postgres-test-1

# Verify services
kubectl get svc -n default | grep postgres-test
```

### Backup/Restore Failures

**Issue**: Backup never completes
```bash
# Check backup status
kubectl get backup -n default

# Check operator logs
kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg | tail -100

# Verify object storage access
kubectl exec -it [primary-pod] -n default -- \
  s3cmd --access_key=minioadmin --secret_key=minioadmin \
  ls s3://postgres-backups/
```

**Issue**: Restore from backup fails
```bash
# Check restore cluster status
kubectl describe cluster postgres-test-restore -n default

# Verify backup metadata
kubectl get backup -n default -o wide
```

### Failover Test Failures

**Issue**: Failover takes too long
```bash
# Check cluster status during failover
watch kubectl get cluster postgres-test -n default

# Check pod events
kubectl describe pod postgres-test-1 -n default

# Verify replication is working
kubectl exec -it [primary-pod] -n default -- \
  psql -U postgres -c "SELECT * FROM pg_stat_replication;"
```

**Issue**: Data loss detected
```bash
# This indicates a critical replication issue
# Check replication configuration in cluster spec
kubectl get cluster postgres-test -n default -o yaml | grep -A 10 "synchronous"

# Verify WAL archiving is enabled
kubectl exec -it [primary-pod] -n default -- \
  psql -U postgres -c "SHOW wal_level;"
```

## Performance Expectations

| Test | Duration | Target |
|------|----------|--------|
| Deployment | 5-10 min | < 5 min for cluster ready |
| Backup | 10-20 min | < 30 min for 10GB |
| Failover | 3-5 min | < 2 min for detection + recovery |

## Advanced Options

### Running with Custom Cluster Config

```bash
# Edit test-cluster.yaml before running tests
kubectl apply -f tests/e2e/fixtures/postgres/test-cluster.yaml
./08-test-postgres-deployment.sh
```

### Running Tests with Different Scenarios

```bash
# Run with S3 instead of MinIO
BACKUP_ENDPOINT=https://s3.amazonaws.com ./09-test-backup-restore.sh

# Run with custom namespace
kubectl apply -f tests/e2e/fixtures/postgres/test-cluster.yaml -n custom-ns
KUBECONFIG=.kubeconfig-custom ./08-test-postgres-deployment.sh
```

### Inspecting Cluster State Between Tests

```bash
# Keep cluster running between tests for inspection
# Don't run 99-cleanup.sh until you're done

# Check cluster status
kubectl get cluster postgres-test -n default -o yaml

# Check pods
kubectl get pods -n default -l cnpg.io/cluster=postgres-test

# Check events
kubectl get events -n default --field-selector involvedObject.kind=Cluster

# Then cleanup when ready
./99-cleanup.sh
```

## References

- [CloudNativePG E2E Tests](https://cloudnative-pg.io/documentation/current/e2e/)
- [CloudNativePG PostgreSQL Backup Recovery](https://cloudnative-pg.io/documentation/current/backup_recovery/)
- [Barman Cloud Plugin](https://barman.readthedocs.io/en/latest/barman_cloud/)
- [PostgreSQL Replication](https://www.postgresql.org/docs/current/warm-standby.html)
