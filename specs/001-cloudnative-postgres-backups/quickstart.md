# PostgreSQL Quickstart Guide

Get PostgreSQL with HA and automated backups running in 5 minutes.

## Prerequisites

- Kubernetes cluster (Kind, EKS, etc.)
- kubectl configured
- 4GB+ available memory
- `make` installed

## 1. Start Development Environment

```bash
# Start Kind cluster with Knative, Flux, and PostgreSQL
make dev-up

# Wait for cluster to be ready (~2-3 minutes)
./scripts/dev/check-postgres-status.sh
```

Expected output:
```
Cluster Status: Cluster in healthy state
Ready Instances: 1
Instance Names: postgres-app-1
...
```

## 2. Connect to PostgreSQL

```bash
# Port-forward PostgreSQL to localhost
./scripts/dev/port-forward-postgres.sh

# In another terminal, connect with psql
psql postgresql://app:PASSWORD@localhost:5432/app

# Or with kubectl
kubectl exec -it postgres-app-1 -- psql -U app -d app
```

## 3. Create Test Data

```bash
# From psql prompt
CREATE TABLE IF NOT EXISTS test_items (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

INSERT INTO test_items (name) VALUES ('Item 1'), ('Item 2'), ('Item 3');

SELECT * FROM test_items;
```

## 4. Create Backup

```bash
# Create on-demand backup
./scripts/dev/create-backup.sh

# Wait for completion (~1-2 minutes)
```

Expected output:
```
Creating manual backup: postgres-app-backup-1704326400
Waiting for backup to complete...
✓ Backup completed successfully!
```

## 5. Verify Backup

```bash
# List backups
./scripts/dev/check-backup-status.sh

# List in object storage (MinIO)
./scripts/dev/list-backups.sh
```

## 6. Test Restore

```bash
# Restore to new cluster
./scripts/dev/restore-from-backup.sh -n test-restore

# Wait for cluster to be ready (~5 minutes)
kubectl get cluster test-restore -w

# Verify data was restored
kubectl exec test-restore-1 -- psql -U app -d app -c "SELECT COUNT(*) FROM test_items;"

# Expected output: 3 rows
```

## 7. Test Failover (Optional)

```bash
# Delete primary pod to trigger failover
kubectl delete pod postgres-app-1

# Watch automatic failover
./scripts/dev/check-postgres-status.sh

# Should show pod recovered and ready in <1 minute
```

## 8. Clean Up

```bash
# Remove test restore cluster
kubectl delete cluster test-restore

# Stop development environment
make dev-down
```

## What You've Learned

- ✓ Deployed production-grade PostgreSQL with HA
- ✓ Created automated backups
- ✓ Restored from backup
- ✓ Tested failover capability
- ✓ Verified data integrity

## Next Steps

### For Operations
- Read [Operations Guide](docs/POSTGRES.md) for production deployment
- Read [Backup & Restore Guide](docs/POSTGRES_BACKUP_RESTORE.md) for detailed procedures
- Set up [Monitoring & Alerting](docs/POSTGRES_MONITORING.md)

### For Application Development
- Connect from your application with connection string:
  ```
  postgresql://app:PASSWORD@postgres-app-rw.default.svc.cluster.local:5432/app
  ```
- Use connection pooling with PgBouncer for production
- Enable `shared_preload_libraries: "pg_stat_statements"` for monitoring

### For High Availability
- Scale to 3 instances for quorum replication:
  ```bash
  kubectl patch cluster postgres-app --type='json' \
    -p='[{"op":"replace","path":"/spec/instances","value":3}]'
  ```
- Configure S3 backups for production
- Set up Grafana dashboards for monitoring

## Troubleshooting

### Cluster not starting
```bash
kubectl describe cluster postgres-app
kubectl logs postgres-app-1
```

### Backup failing
```bash
./scripts/dev/check-backup-status.sh
kubectl logs -l app.kubernetes.io/name=cloudnative-pg -n cnpg-system
```

### Connection issues
```bash
# Check services
kubectl get svc | grep postgres

# Test connectivity
kubectl exec -it postgres-app-1 -- psql -U postgres -c "SELECT 1;"
```

## Documentation

| Guide | Purpose |
|-------|---------|
| [POSTGRES.md](docs/POSTGRES.md) | Complete operations guide |
| [POSTGRES_BACKUP_RESTORE.md](docs/POSTGRES_BACKUP_RESTORE.md) | Backup, restore, and PITR procedures |
| [POSTGRES_MONITORING.md](docs/POSTGRES_MONITORING.md) | Metrics, alerts, and Grafana setup |

## Success Criteria

You've successfully completed the quickstart when:

- [ ] PostgreSQL cluster deployed and healthy
- [ ] Can connect via psql to `localhost:5432`
- [ ] Created and verified backup exists
- [ ] Restored from backup to new cluster
- [ ] Data verified in restored cluster
- [ ] Pod failover works automatically

Congratulations! 🎉
