# Operational Runbooks

Procedures for operating {{ project_name }} in production.

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
- Redis connection failed{% if feature_s3 %}
- S3 operation failures{% endif %}

**Manual Detection**:
```bash
# Check error rate
curl http://localhost:8080/metrics | grep http_request_total | grep 5..

# Check latency
curl http://localhost:8080/metrics | grep http_request_duration_seconds

# Check pod status
kubectl get pods -n {{ project_name }}

# Check workload status
{% if workload_type == "Deployment" %}
kubectl get deployment,service,pdb {{ project_name }} -n {{ project_name }}
{% else %}
kubectl get ksvc {{ project_name }} -n {{ project_name }}
{% endif %}
```

### Step 2: Respond

**Declare Incident**:
```bash
# Create incident channel
# Slack: #incident-{{ project_name }}-TIMESTAMP

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
kubectl rollout undo deployment/{{ project_name }} -n {{ project_name }}

# Scale up (if resource constrained)
kubectl scale deployment/{{ project_name }} --replicas=20 -n {{ project_name }}

# Kill slow pods
kubectl delete pod <pod-name> -n {{ project_name }}

# Disable canary (shift all traffic to stable)
{% if workload_type == "Knative" %}
kubectl set traffic {{ project_name }} --revision={{ project_name }}-stable --percent=100
{% endif %}
```

**Debug**:
```bash
# View logs
kubectl logs -f deployment/{{ project_name }} -n {{ project_name }}

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
docker build -t {{ image_registry }}/{{ github_org }}/{{ project_name }}:fix-v1 .
docker push {{ image_registry }}/{{ github_org }}/{{ project_name }}:fix-v1

# Deploy (via GitOps or manual)
kubectl set image deployment/{{ project_name }} user-container={{ image_registry }}/{{ github_org }}/{{ project_name }}:fix-v1 -n {{ project_name }}

# Verify deployment
kubectl rollout status deployment/{{ project_name }} -n {{ project_name }}
```

**Fix Configuration**:
```bash
# Edit ConfigMap
kubectl edit configmap {{ project_name }}-config -n {{ project_name }}

# Edit Secret
kubectl edit secret {{ project_name }}-secrets -n {{ project_name }}

# Rollout restart (to pick up new config)
kubectl rollout restart deployment/{{ project_name }} -n {{ project_name }}
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
# Post-Mortem: {{ project_name }} Incident [Date]

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

{% if workload_type == "Deployment" %}
Deployment replicas are GitOps-managed. Change the per-environment
`workload.replicas` value in the overlay (or the base HelmRelease) and let Flux
reconcile. A manual `kubectl scale` is reverted by Flux on the next reconcile.

```bash
# Edit the overlay, commit, and let Flux reconcile:
# deploy/overlays/<env>/kustomization.yaml -> /spec/values/services/app/workload/replicas
kubectl scale deployment/{{ project_name }} --replicas=20 -n {{ project_name }}   # temporary only

# Verify
kubectl get pods -n {{ project_name }} -l app.kubernetes.io/name={{ project_name }}
kubectl get deployment {{ project_name }} -n {{ project_name }}
```
{% else %}
### Manual Scale Up

```bash
# Scale to 20 replicas
kubectl scale deployment/{{ project_name }} --replicas=20 -n {{ project_name }}

# Verify
kubectl get pods -n {{ project_name }} -l serving.knative.dev/service={{ project_name }}
```

### Manual Scale Down

```bash
# Scale to 5 replicas
kubectl scale deployment/{{ project_name }} --replicas=5 -n {{ project_name }}
```

### Adjust Auto-scaling

**Edit Knative Service**:
```bash
kubectl edit ksvc {{ project_name }} -n {{ project_name }}
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
kubectl patch ksvc {{ project_name }} -n {{ project_name }} -p '{"spec":{"template":{"metadata":{"annotations":{"autoscaling.knative.dev/minScale":"50"}}}}}'

# After event, reduce
kubectl patch ksvc {{ project_name }} -n {{ project_name }} -p '{"spec":{"template":{"metadata":{"annotations":{"autoscaling.knative.dev/minScale":"5"}}}}}'
```
{% endif %}

---

## Backups

{% if feature_s3 %}

### S3 Backup Strategy

**Versioning Enabled**:
- Automatic versioning for all objects
- Keeps all versions (until lifecycle policy)
- Can restore previous versions

**Enable Versioning**:
```bash
aws s3api put-bucket-versioning \
  --bucket {{ project_name }}-data \
  --versioning-configuration Status=Enabled
```

**List Object Versions**:
```bash
aws s3api list-object-versions \
  --bucket {{ project_name }}-data \
  --prefix "documents/"
```

**Restore Previous Version**:
```bash
aws s3api copy-object \
  --bucket {{ project_name }}-data \
  --copy-source {{ project_name }}-data/documents/file.txt?versionId=VERSION_ID \
  --key documents/file.txt
```

### Cross-Region Replication

**Enable Replication**:
```bash
aws s3api put-bucket-replication \
  --bucket {{ project_name }}-data-primary \
  --replication-configuration '{
    "Role": "arn:aws:iam::ACCOUNT_ID:role/replication-role",
    "Rules": [
      {
        "Status": "Enabled",
        "Prefix": "",
        "Destination": {
          "Bucket": "arn:aws:s3:::{{ project_name }}-data-backup",
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
  --bucket {{ project_name }}-data \
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

{% endif %}

### Configuration Backup

**Export ConfigMaps and Secrets**:
```bash
# Backup ConfigMaps
kubectl get configmaps -n {{ project_name }} -o yaml > configmaps-backup.yaml

# Backup Secrets (WARNING: Contains sensitive data!)
kubectl get secrets -n {{ project_name }} -o yaml > secrets-backup.yaml
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

{% if feature_s3 %}# S3 backup (metadata only)
aws s3 sync s3://{{ project_name }}-data/ s3://{{ project_name }}-data-backup/
{% endif %}
```

**Step 2: Deploy New Version**:
```bash
# Deploy with new schema/migration
kubectl set image deployment/{{ project_name }} user-container={{ image_registry }}/{{ github_org }}/{{ project_name }}:v2.0 -n {{ project_name }}

# Verify deployment
kubectl rollout status deployment/{{ project_name }} -n {{ project_name }}
```

**Step 3: Run Migration**:
```bash
# If migration needs to run manually
kubectl exec -it deployment/{{ project_name }} -n {{ project_name }} -- sh
# Run migration command
./app migrate
```

**Step 4: Verify**:
```bash
# Test application
curl http://<service-url>/health/ready

# Check logs for migration errors
kubectl logs deployment/{{ project_name }} -n {{ project_name }}
```

**Step 5: Rollback if Needed**:
```bash
kubectl rollout undo deployment/{{ project_name }} -n {{ project_name }}
```

---

## Maintenance Windows

{% if workload_type == "Deployment" %}
> This project uses a Deployment workload. For planned maintenance, scale the
> Deployment with `kubectl scale deployment/{{ project_name }} --replicas=0`
> (temporary; Flux restores the Git-declared replica count) and scale it back
> after maintenance. The Knative annotation patches below do not apply.
{% endif %}

### Planned Maintenance

**Step 1: Announce**:
- 1 week notice for users
- 24 hours notice for urgent maintenance
- Update status page

**Step 2: Prepare**:
```bash
{% if workload_type == "Deployment" %}
# Scale down gracefully
kubectl scale deployment/{{ project_name }} --replicas=0 -n {{ project_name }}

# Wait for pods to terminate
kubectl wait --for=delete pods -l app.kubernetes.io/name={{ project_name }} -n {{ project_name }} --timeout=300s
{% else %}
# Scale down gracefully
kubectl patch ksvc {{ project_name }} -n {{ project_name }} -p '{"spec":{"template":{"metadata":{"annotations":{"autoscaling.knative.dev/minScale":"0"}}}}}'

# Wait for pods to terminate
kubectl wait --for=delete pods -l serving.knative.dev/service={{ project_name }} -n {{ project_name }} --timeout=300s
{% endif %}
```

**Step 3: Perform Maintenance**:
- Database migrations
- Configuration updates
- Infrastructure upgrades
- Apply security patches

**Step 4: Verify**:
```bash
{% if workload_type == "Deployment" %}
# Scale up (or let Flux restore the Git-declared replica count)
kubectl scale deployment/{{ project_name }} --replicas=3 -n {{ project_name }}

# Wait for the rollout
kubectl rollout status deployment/{{ project_name }} -n {{ project_name }} --timeout=300s
{% else %}
# Scale up
kubectl patch ksvc {{ project_name }} -n {{ project_name }} -p '{"spec":{"template":{"metadata":{"annotations":{"autoscaling.knative.dev/minScale":"5"}}}}}'

# Wait for pods to be ready
kubectl wait --for=condition=ready ksvc {{ project_name }} -n {{ project_name }} --timeout=300s
{% endif %}

# Test health
kubectl exec deployment/{{ project_name }} -n {{ project_name }} -- curl localhost:8080/health/ready
```

### Rolling Updates (No Downtime)

{% if workload_type == "Deployment" %}
The generated Deployment uses `maxUnavailable: 0` and `maxSurge: 1`, so a new
pod starts before an old one is removed. `preStopSleepSeconds` gives endpoints
time to drain; clients reconnect if a rolling update interrupts a long stream.
{% else %}
Knative supports zero-downtime deployments automatically:

1. Deploy new image
2. New pods start with new revision
3. Traffic gradually shifts (if configured)
4. Old pods drained after timeout
{% endif %}

{% if workload_type == "Knative" %}
**Configure Traffic Split**:
```bash
# Gradual rollout
kubectl set traffic {{ project_name }} \
  --revision={{ project_name }}-00001=90 \
  --revision={{ project_name }}-00002=10 \
  -n {{ project_name }}
```
{% endif %}

---

## Emergency Procedures

### Emergency Shutdown

**Complete Outage Required**:
```bash
{% if workload_type == "Deployment" %}
# Scale to zero (emergency; Flux will restore replicas on the next reconcile)
kubectl scale deployment/{{ project_name }} --replicas=0 -n {{ project_name }}

# Wait for termination
kubectl wait --for=delete pods -l app.kubernetes.io/name={{ project_name }} -n {{ project_name }}
{% else %}
# Scale to zero (emergency)
kubectl patch ksvc {{ project_name }} -n {{ project_name }} -p '{"spec":{"template":{"metadata":{"annotations":{"autoscaling.knative.dev/minScale":"0"}}}}}'

# Wait for termination
kubectl wait --for=delete pods -l serving.knative.dev/service={{ project_name }} -n {{ project_name }}
{% endif %}
```

### Emergency Database Restore

```bash
# Stop application
kubectl scale deployment/{{ project_name }} --replicas=0 -n {{ project_name }}

# Restore from backup
# ... restore procedure ...

# Restart application
kubectl scale deployment/{{ project_name }} --replicas=5 -n {{ project_name }}
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
kubectl get pods -n {{ project_name }}
kubectl logs deployment/{{ project_name }} -n {{ project_name }}
```

---

## Next Steps

- **Monitoring**: See `docs/MONITORING.md`
- **Deployment**: See `docs/DEPLOYMENT.md`
- **Troubleshooting**: See `docs/TROUBLESHOOTING.md`
- **Security**: See `docs/SECURITY.md`
