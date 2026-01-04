# PostgreSQL Monitoring and Alerting

This guide covers monitoring CloudNativePG PostgreSQL clusters using Prometheus and Grafana.

## Overview

PostgreSQL metrics are exposed through:
- **PodMonitor**: Kubernetes Prometheus Operator resource for discovering and scraping CloudNativePG pods
- **PrometheusRule**: Alert rules for backup health, replication, and instance availability

## Metrics Collection

### PodMonitor Configuration

The `postgres-podmonitor.yaml` deploys two PodMonitors:

1. **postgres-metrics**: Scrapes metrics from PostgreSQL pods in the `default` namespace
   - Target: Pods with `postgresql={{ project_name }}-postgres` label
   - Port: `metrics` (9187)
   - Interval: 30 seconds
   - Scheme: HTTP

2. **cnpg-operator-metrics**: Scrapes metrics from CloudNativePG operator
   - Target: `cnpg-system` namespace, app `cloudnative-pg`
   - Port: `metrics` (8080)
   - Interval: 30 seconds

### Key Metrics

#### Backup Metrics

| Metric | Description |
|--------|-------------|
| `cnpg_collector_backup_last_failed_timestamp` | Unix timestamp of last failed backup |
| `cnpg_collector_last_failed_backup_timestamp` | Unix timestamp of last backup failure |
| `cnpg_collector_backup_size_bytes` | Size of last backup in bytes |
| `cnpg_collector_backup_duration_seconds` | Duration of last backup in seconds |
| `cnpg_pg_stat_archiver_failed_count` | Number of failed WAL archiving attempts |

#### Replication Metrics

| Metric | Description |
|--------|-------------|
| `cnpg_pg_replication_lag` | Replication lag in seconds |
| `pg_stat_replication_write_lag_bytes` | Write lag to standby in bytes |
| `pg_stat_replication_flush_lag_bytes` | Flush lag to standby in bytes |
| `pg_stat_replication_replay_lag_bytes` | Replay lag on standby in bytes |

#### Instance Health Metrics

| Metric | Description |
|--------|-------------|
| `pg_up` | PostgreSQL instance is up (1) or down (0) |
| `pg_setting_server_version_num` | PostgreSQL version number |
| `pg_stat_activity_count` | Number of active connections |
| `pg_is_in_recovery` | Instance is in recovery mode (1) or primary (0) |

#### Operator Metrics

| Metric | Description |
|--------|-------------|
| `cnpg_operator_webhooks_validation_total` | Total validation webhook calls |
| `cnpg_operator_configuration_errors_total` | Total configuration errors detected |

## Alert Rules

All alerts are defined in `postgres-alerts.yaml` and organized by category:

### Backup Health Alerts

- **PostgreSQLBackupFailed** (CRITICAL)
  - Triggers: Backup failed in last 5 minutes
  - Action: Verify backup storage connectivity, check operator logs

- **PostgreSQLBackupMissing** (WARNING)
  - Triggers: No successful backup in 24 hours
  - Action: Verify backup schedule, check for storage quota issues

### Replication Alerts

- **PostgreSQLReplicationLag** (WARNING)
  - Triggers: Replication lag > 10 seconds for 5 minutes
  - Action: Check replica capacity, network latency, primary load

- **PostgreSQLHighReplicationLag** (CRITICAL)
  - Triggers: Replication lag > 60 seconds for 2 minutes
  - Action: Immediate investigation - failover may be imminent

### Instance Availability Alerts

- **PostgreSQLInstanceDown** (CRITICAL)
  - Triggers: Pod not responding to metrics scrape for 1 minute
  - Action: Check pod logs, verify storage is accessible

- **PostgreSQLNotReady** (WARNING)
  - Triggers: Instance not reporting version (still starting)
  - Action: Monitor logs, wait for startup to complete

### Storage Alerts

- **PostgreSQLDiskLow** (WARNING)
  - Triggers: Disk space < 10% for 10 minutes
  - Action: Add storage capacity, archive old data, increase PVC size

### WAL Archiving Alerts

- **PostgreSQLWALArchivingFailed** (WARNING)
  - Triggers: WAL archiving failures detected
  - Action: Verify backup storage credentials, check network connectivity

### Connection Alerts

- **PostgreSQLHighConnections** (WARNING)
  - Triggers: Active connections > 50 for 5 minutes
  - Action: Investigate application behavior, consider connection pooling

### Recovery Alerts

- **PostgreSQLRecoveryInProgress** (WARNING)
  - Triggers: Instance in recovery mode
  - Action: For replicas, this is normal; for primary, investigate

## Grafana Dashboards

### Official CloudNativePG Dashboard

CloudNativePG provides official Grafana dashboards in the repository:
https://github.com/cloudnative-pg/grafana-dashboards

To import:

1. **Via Grafana UI**:
   - Go to Grafana → Dashboards → New → Import
   - Enter dashboard ID or paste JSON from repository
   - Select Prometheus as data source
   - Click Import

2. **Via ConfigMap** (recommended for GitOps):
   ```bash
   # Download dashboard JSON
   curl -o postgres-dashboard.json \
     https://raw.githubusercontent.com/cloudnative-pg/grafana-dashboards/main/postgres.json
   
   # Create ConfigMap
   kubectl create configmap grafana-postgres-dashboard \
     --from-file=postgres-dashboard.json \
     -n monitoring
   
   # Configure Grafana to use ConfigMap volume
   ```

### Key Panels

- **Cluster Health**: Instance status, ready/total counts
- **Replication Status**: Replication lag, standby names
- **Backup Status**: Last backup time, size, duration
- **WAL Archiving**: Failed archives, bytes archived
- **Query Performance**: Slow queries, cache hit ratio
- **Storage Usage**: Table sizes, index sizes, cache usage
- **Connections**: Active connections by application

## Setting Up Monitoring

### Prerequisites

- Prometheus Operator must be deployed (includes PodMonitor CRD)
- Prometheus instance configured to discover PodMonitors
- Grafana with Prometheus data source configured

### Deployment

The monitoring resources are deployed as part of the PostgreSQL base configuration:

```bash
# Overlays automatically include monitoring
kubectl apply -k deploy/overlays/dev/

# Verify PodMonitors
kubectl get podmonitor -n default
kubectl describe podmonitor postgres-metrics

# Verify PrometheusRules
kubectl get prometheusrule
kubectl describe prometheusrule postgres-alerts
```

### Verification

```bash
# Check metrics are being scraped
kubectl logs -l app=prometheus -n monitoring | grep postgres-metrics

# Query Prometheus for metrics
# (via Prometheus UI or PromQL query)
# Example: up{job="postgres-metrics"}

# Check alerts are being evaluated
# (via Prometheus UI: Alerts tab)
```

## Dashboarding Best Practices

1. **Use official CloudNativePG dashboards** for consistency
2. **Customize with environment-specific panels** (dev/staging/prod)
3. **Set appropriate warning thresholds** for your SLOs
4. **Document dashboard panels** with runbook links
5. **Version control dashboard JSON** in Git

## Troubleshooting

### PodMonitor not discovering pods

```bash
# Verify PodMonitor has correct label selectors
kubectl get podmonitor postgres-metrics -o yaml | grep -A 5 selector

# Verify PostgreSQL pods have matching labels
kubectl get pods -L postgresql,role

# Check Prometheus service monitor status
kubectl logs -l app=prometheus -n monitoring | grep "added targets"
```

### Metrics not appearing in Prometheus

```bash
# Verify Prometheus can reach PostgreSQL pods
kubectl port-forward -n default svc/{{ project_name }}-postgres-rw 9187:9187

curl http://localhost:9187/metrics

# Check Prometheus scrape configs
kubectl get prometheus -n monitoring -o yaml | grep -A 10 podMonitorSelector
```

### Alerts not firing

```bash
# Verify PrometheusRule is loaded
kubectl get prometheusrule postgres-alerts -o yaml

# Check Prometheus rule groups
kubectl exec -it prometheus-pod -n monitoring -- \
  curl http://localhost:9090/api/v1/rules | jq '.data.groups[] | select(.file | contains("postgres"))'

# Manually test alert conditions
# (via Prometheus UI: Graph tab)
```

## Alert Runbooks

### When PostgreSQLBackupFailed fires

1. **Check backup status**: `./scripts/dev/check-backup-status.sh`
2. **Review operator logs**: `kubectl logs -l app.kubernetes.io/name=cloudnative-pg -n cnpg-system`
3. **Verify storage connectivity**:
   ```bash
   # MinIO example
   kubectl exec -it {{ project_name }}-postgres-1 -- \
     s3cmd -c /opt/postgres/barmanrc get s3://postgres-backups/ /tmp/
   ```
4. **Check operator version**: `kubectl get pods -n cnpg-system`
5. **Escalate if unresolved**: Page on-call DBA

### When PostgreSQLReplicationLag is high

1. **Check replica status**: `kubectl describe cluster {{ project_name }}-postgres`
2. **Check replica logs**: `kubectl logs {{ project_name }}-postgres-2`
3. **Monitor network**: Check cluster node network latency
4. **Review primary load**: Query `pg_stat_statements` on primary
5. **Consider failover prep** if lag continues > 60s

### When PostgreSQLInstanceDown fires

1. **Check pod status**: `kubectl get pod {{ project_name }}-postgres-N -o wide`
2. **Check pod events**: `kubectl describe pod {{ project_name }}-postgres-N`
3. **Review pod logs**: `kubectl logs {{ project_name }}-postgres-N`
4. **Verify PVC**: `kubectl get pvc`
5. **If lost pod**: Wait for CloudNativePG to recreate, verify data integrity after recovery

## Performance Tuning

### Scrape Interval

Default: 30 seconds (balance between freshness and load)

**Increase for stable clusters**: 60s or 120s (reduce Prometheus storage)
**Decrease for critical clusters**: 15s (increase monitoring frequency)

```yaml
podMetricsEndpoints:
  - port: metrics
    interval: 60s  # Adjust as needed
```

### Retention Policy

Configure Prometheus retention:

```bash
# 7 days is typical for monitoring
# Adjust based on storage capacity and analysis needs
prometheus --storage.tsdb.retention.time=7d
```

### Alert Evaluation

Tune `for` duration to balance between:
- **Too short** (< 1m): Triggers on transient issues
- **Too long** (> 10m): Delayed alerting on real issues

Example adjustments for your environment:
- Development: 1-2 minutes
- Staging: 2-5 minutes
- Production: 5-10 minutes

## Additional Resources

- [CloudNativePG Monitoring Documentation](https://cloudnative-pg.io/documentation/current/monitoring/)
- [Prometheus Operator PodMonitor](https://prometheus-operator.dev/docs/operator/latest/api/#monitoring.coreos.com/v1.PodMonitor)
- [CloudNativePG Grafana Dashboards](https://github.com/cloudnative-pg/grafana-dashboards)
- [PostgreSQL Exporter Metrics](https://github.com/prometheus-community/postgres_exporter)
