# Operational Runbooks

Procedures for operating audio-exporter in production.

## Table of Contents

- [Incident Response](#incident-response)
- [Scaling](#scaling)
- [Backups](#backups)
- [Migrations](#migrations)
- [Maintenance Windows](#maintenance-windows)
- [Emergency Procedures](#emergency-procedures)

---

## Incident Response

### Severity Levels

| Severity | Impact | Response Time |
|-----------|---------|---------------|
| P0 | Complete outage | 15 minutes |
| P1 | Degraded service | 1 hour |
| P2 | Partial impact | 4 hours |
| P3 | Minor issue | 24 hours |

### Incident Lifecycle

```
1. Detect → 2. Respond → 3. Mitigate → 4. Resolve → 5. Post-Mortem
```

### Step 1: Detect

**Alerts** (PagerDuty/Slack):
- High error rate
- High latency (P95 > 1s)
- Pod not ready
- Redis connection failed
- S3 operation failures

**Manual Detection**:
```bash
# Check error rate
curl http://localhost:8080/metrics | grep http_request_total | grep 5..

# Check latency
curl http://localhost:8080/metrics | grep http_request_duration_seconds

# Check pod status
kubectl get pods -n audio-exporter

# Check service status
kubectl get ksvc audio-exporter -n audio-exporter
```

### Step 2: Respond

**Declare Incident**:
```bash
# Create incident channel
# Slack: #incident-audio-exporter-TIMESTAMP

# Assign on-call engineer
# Page on-call team
```

**Document**:
- Start time
- Severity
- Symptoms
- Initial assessment

### Step 3: Mitigate

**Quick Wins**:
```bash
# Rollback to previous version
kubectl rollout undo deployment/audio-exporter -n audio-exporter

# Scale up (if resource constrained)
kubectl scale deployment/audio-exporter --replicas=20 -n audio-exporter

# Kill slow pods
kubectl delete pod <pod-name> -n audio-exporter

# Disable canary (shift all traffic to stable)
kubectl set traffic audio-exporter --revision=audio-exporter-stable --percent=100
```

**Debug**:
```bash
# View logs
kubectl logs -f deployment/audio-exporter -n audio-exporter

# View traces
# Navigate to Jaeger: http://jaeger.example.com

# Check metrics
# Navigate to Prometheus: http://prometheus.example.com
```

### Step 4: Resolve

**Fix Deployment**:
```bash
# Fix code
# ... make changes ...

# Run tests
cargo test

# Build and push image
docker build -t ghcr.io/enchantednatures/audio-exporter:fix-v1 .
docker push ghcr.io/enchantednatures/audio-exporter:fix-v1

# Deploy (via GitOps or manual)
kubectl set image deployment/audio-exporter user-container=ghcr.io/enchantednatures/audio-exporter:fix-v1 -n audio-exporter

# Verify deployment
kubectl rollout status deployment/audio-exporter -n audio-exporter
```

**Fix Configuration**:
```bash
# Edit ConfigMap
kubectl edit configmap audio-exporter-config -n audio-exporter

# Edit Secret
kubectl edit secret audio-exporter-secrets -n audio-exporter

# Rollout restart (to pick up new config)
kubectl rollout restart deployment/audio-exporter -n audio-exporter
```

### Step 5: Post-Mortem

**Within 1 Week**:

1. **Timeline**: What happened and when
2. **Impact**: Who was affected
3. **Root Cause**: Why did it happen
4. **Resolution**: How was it fixed
5. **Action Items**: Prevent recurrence

**Template**:
```markdown
# Post-Mortem: audio-exporter Incident [Date]

## Summary
[Brief description of incident]

## Timeline
- 14:00 UTC: Alert triggered (high error rate)
- 14:05 UTC: On-call engaged
- 14:15 UTC: Mitigation (rollback)
- 14:30 UTC: Root cause identified
- 15:00 UTC: Fix deployed
- 15:05 UTC: Incident resolved

## Impact
- Affected users: ~10,000
- Duration: 65 minutes
- Severity: P0

## Root Cause
[Detailed analysis of why incident occurred]

## Resolution
[Steps taken to fix the issue]

## Action Items
- [ ] Add monitoring for X
- [ ] Implement Y
- [ ] Update runbook
```

---

## Scaling

### Manual Scale Up

```bash
# Scale to 20 replicas
kubectl scale deployment/audio-exporter --replicas=20 -n audio-exporter

# Verify
kubectl get pods -n audio-exporter -l serving.knative.dev/service=audio-exporter
```

### Manual Scale Down

```bash
# Scale to 5 replicas
kubectl scale deployment/audio-exporter --replicas=5 -n audio-exporter
```

### Adjust Auto-scaling

**Edit Knative Service**:
```bash
kubectl edit ksvc audio-exporter -n audio-exporter
```

**Update Annotations**:
```yaml
annotations:
  autoscaling.knative.dev/minScale: "10"      # Min replicas
  autoscaling.knative.dev/maxScale: "100"     # Max replicas
  autoscaling.knative.dev/target: "100"       # Target concurrency
  autoscaling.knative.dev/targetUtilizationPercentage: "70"  # CPU utilization
```

### Scale for Events

**Prepare for traffic spike**:
```bash
# Increase min-scale before event
kubectl patch ksvc audio-exporter -n audio-exporter -p '{"spec":{"template":{"metadata":{"annotations":{"autoscaling.knative.dev/minScale":"50"}}}}}'

# After event, reduce
kubectl patch ksvc audio-exporter -n audio-exporter -p '{"spec":{"template":{"metadata":{"annotations":{"autoscaling.knative.dev/minScale":"5"}}}}}'
```

---

## Backups



### S3 Backup Strategy

**Versioning Enabled**:
- Automatic versioning for all objects
- Keeps all versions (until lifecycle policy)
- Can restore previous versions

**Enable Versioning**:
```bash
aws s3api put-bucket-versioning \
  --bucket audio-exporter-data \
  --versioning-configuration Status=Enabled
```

**List Object Versions**:
```bash
aws s3api list-object-versions \
  --bucket audio-exporter-data \
  --prefix "documents/"
```

**Restore Previous Version**:
```bash
aws s3api copy-object \
  --bucket audio-exporter-data \
  --copy-source audio-exporter-data/documents/file.txt?versionId=VERSION_ID \
  --key documents/file.txt
```

### Cross-Region Replication

**Enable Replication**:
```bash
aws s3api put-bucket-replication \
  --bucket audio-exporter-data-primary \
  --replication-configuration '{
    "Role": "arn:aws:iam::ACCOUNT_ID:role/replication-role",
    "Rules": [
      {
        "Status": "Enabled",
        "Prefix": "",
        "Destination": {
          "Bucket": "arn:aws:s3:::audio-exporter-data-backup",
          "StorageClass": "STANDARD"
        }
      }
    ]
  }'
```

### Lifecycle Policies

**Delete old versions after 90 days**:
```bash
aws s3api put-bucket-lifecycle-configuration \
  --bucket audio-exporter-data \
  --lifecycle-configuration '{
    "Rules": [
      {
        "ID": "DeleteOldVersions",
        "Status": "Enabled",
        "Filter": {},
        "NoncurrentVersionExpiration": {
          "NoncurrentDays": 90
        }
      }
    ]
  }'
```



### Configuration Backup

**Export ConfigMaps and Secrets**:
```bash
# Backup ConfigMaps
kubectl get configmaps -n audio-exporter -o yaml > configmaps-backup.yaml

# Backup Secrets (WARNING: Contains sensitive data!)
kubectl get secrets -n audio-exporter -o yaml > secrets-backup.yaml
# Encrypt backup file
gpg -c secrets-backup.yaml
rm secrets-backup.yaml
```

**Restore ConfigMaps**:
```bash
kubectl apply -f configmaps-backup.yaml
```

**Restore Secrets**:
```bash
gpg secrets-backup.yaml.gpg
kubectl apply -f secrets-backup.yaml
shred -u secrets-backup.yaml
```

---

## Migrations

### Database/Redis Migration

**Step 1: Backup Data**:
```bash
# Redis backup
redis-cli --rdb backup.rdb
kubectl cp backup.rdb redis-0:/tmp/backup.rdb -n redis

# S3 backup (metadata only)
aws s3 sync s3://audio-exporter-data/ s3://audio-exporter-data-backup/

```

**Step 2: Deploy New Version**:
```bash
# Deploy with new schema/migration
kubectl set image deployment/audio-exporter user-container=ghcr.io/enchantednatures/audio-exporter:v2.0 -n audio-exporter

# Verify deployment
kubectl rollout status deployment/audio-exporter -n audio-exporter
```

**Step 3: Run Migration**:
```bash
# If migration needs to run manually
kubectl exec -it deployment/audio-exporter -n audio-exporter -- sh
# Run migration command
./app migrate
```

**Step 4: Verify**:
```bash
# Test application
curl http://<service-url>/health/ready

# Check logs for migration errors
kubectl logs deployment/audio-exporter -n audio-exporter
```

**Step 5: Rollback if Needed**:
```bash
kubectl rollout undo deployment/audio-exporter -n audio-exporter
```

---

## Maintenance Windows

### Planned Maintenance

**Step 1: Announce**:
- 1 week notice for users
- 24 hours notice for urgent maintenance
- Update status page

**Step 2: Prepare**:
```bash
# Scale down gracefully
kubectl patch ksvc audio-exporter -n audio-exporter -p '{"spec":{"template":{"metadata":{"annotations":{"autoscaling.knative.dev/minScale":"0"}}}}}'

# Wait for pods to terminate
kubectl wait --for=delete pods -l serving.knative.dev/service=audio-exporter -n audio-exporter --timeout=300s
```

**Step 3: Perform Maintenance**:
- Database migrations
- Configuration updates
- Infrastructure upgrades
- Apply security patches

**Step 4: Verify**:
```bash
# Scale up
kubectl patch ksvc audio-exporter -n audio-exporter -p '{"spec":{"template":{"metadata":{"annotations":{"autoscaling.knative.dev/minScale":"5"}}}}}'

# Wait for pods to be ready
kubectl wait --for=condition=ready ksvc audio-exporter -n audio-exporter --timeout=300s

# Test health
kubectl exec deployment/audio-exporter -n audio-exporter -- curl localhost:8080/health/ready
```

### Rolling Updates (No Downtime)

Knative supports zero-downtime deployments automatically:

1. Deploy new image
2. New pods start with new revision
3. Traffic gradually shifts (if configured)
4. Old pods drained after timeout

**Configure Traffic Split**:
```bash
# Gradual rollout
kubectl set traffic audio-exporter \
  --revision=audio-exporter-00001=90 \
  --revision=audio-exporter-00002=10 \
  -n audio-exporter
```

---

## Emergency Procedures

### Emergency Shutdown

**Complete Outage Required**:
```bash
# Scale to zero (emergency)
kubectl patch ksvc audio-exporter -n audio-exporter -p '{"spec":{"template":{"metadata":{"annotations":{"autoscaling.knative.dev/minScale":"0"}}}}}'

# Wait for termination
kubectl wait --for=delete pods -l serving.knative.dev/service=audio-exporter -n audio-exporter
```

### Emergency Database Restore

```bash
# Stop application
kubectl scale deployment/audio-exporter --replicas=0 -n audio-exporter

# Restore from backup
# ... restore procedure ...

# Restart application
kubectl scale deployment/audio-exporter --replicas=5 -n audio-exporter
```

### Disaster Recovery

**Complete Cluster Recovery**:
```bash
# 1. Restore Kubernetes manifests
kubectl apply -f backups/k8s-manifests/

# 2. Restore Secrets
gpg secrets-backup.yaml.gpg
kubectl apply -f secrets-backup.yaml

# 3. Restore S3 data (if needed)
# ... restore procedure ...

# 4. Verify application
kubectl get pods -n audio-exporter
kubectl logs deployment/audio-exporter -n audio-exporter
```

---

## Next Steps

- **Monitoring**: See `docs/MONITORING.md`
- **Deployment**: See `docs/DEPLOYMENT.md`
- **Troubleshooting**: See `docs/TROUBLESHOOTING.md`
- **Security**: See `docs/SECURITY.md`
