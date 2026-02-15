# Deployment Guide

Complete guide for deploying {{ project_name }} to Kubernetes using Knative Serving and FluxCD GitOps.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Local Testing](#local-testing)
- [Manual Kubernetes Deployment](#manual-kubernetes-deployment)
- [FluxCD GitOps Deployment](#fluxcd-gitops-deployment)
- [Environment-Specific Deployment](#environment-specific-deployment)
- [Rollback Procedures](#rollback-procedures)
- [Traffic Splitting](#traffic-splitting)
- [Monitoring Deployments](#monitoring-deployments)

---

## Prerequisites

### Required Software

| Software | Version | Purpose |
|----------|---------|---------|
| kubectl | 1.24+ | Kubernetes CLI |
| Knative Serving | 1.12+ | Serverless platform |
| FluxCD CLI | 2.0+ | GitOps tool |
| Docker | 20.10+ | Container build |
| helm | 3.x+ | Package manager (optional) |

### Kubernetes Cluster

**Recommended for Production**:
- EKS (AWS), GKE (Google), AKS (Azure)
- 3+ nodes for high availability
- 8+ GB RAM per node
- 50+ GB storage

**For Development/Testing**:
- Kind (Kubernetes in Docker)
- Minikube
- Local development cluster

### Install Knative Serving

```bash
# Install Knative Serving with Kourier networking
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.12.0/serving-crds.yaml
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.12.0/serving-core.yaml
kubectl apply -f https://github.com/knative/net-kourier/releases/download/knative-v1.12.0/kourier.yaml

# Configure Kourier as default ingress
kubectl patch configmap/config-network \
  --namespace knative-serving \
  --type merge \
  --patch '{"data":{"ingress.class":"kourier.ingress.networking.knative.dev"}}'

# Verify installation
kubectl get pods -n knative-serving
```

### Install FluxCD

```bash
# Install FluxCD CLI
curl -s https://fluxcd.io/install.sh | sudo bash

# Verify installation
flux --version

# Bootstrap FluxCD in your cluster
flux bootstrap github \
  --owner=your-org \
  --repo=your-repo \
  --personal \
  --path=clusters/production
```

---

## Local Testing

Before deploying to Kubernetes, test locally:

### 1. Build Docker Image

```bash
# Build image
docker build -t {{ project_name }}:latest .

# Tag for registry
docker tag {{ project_name }}:latest {{ image_registry }}/{{ github_org }}/{{ project_name }}:v1.0.0

# Push to registry
docker push {{ image_registry }}/{{ github_org }}/{{ project_name }}:v1.0.0
```

### 2. Test with Kind Development Environment

```bash
# Start development environment
make dev-up

# Verify health
curl http://localhost:8080/health/live
curl http://localhost:8080/health/ready

# Test API
{% if feature_s3 %}
curl -X POST http://localhost:8080/api/upload \
  -H "Content-Type: application/json" \
  -d '{"key":"test.txt","data":"aGVsbG8="}'
{% else %}
curl http://localhost:8080/metrics
{% endif %}

# View logs
make dev-logs
```

### 3. Run Integration Tests

```bash
# Start development environment
make dev-up

# Run tests
cargo test -- --ignored --nocapture
```

---

## Manual Kubernetes Deployment

### Create Namespace

```bash
kubectl create namespace {{ project_name }}
```

### Create Secrets

```bash
# Redis connection
kubectl create secret generic {{ project_name }}-secrets \
  --from-literal=redis-url='redis://redis:6379' \
  -n {{ project_name }}

{% if feature_s3 %}
# S3 credentials
kubectl create secret generic {{ project_name }}-s3 \
  --from-literal=aws-access-key-id='your-access-key' \
  --from-literal=aws-secret-access-key='your-secret-key' \
  -n {{ project_name }}
{% endif %}
```

### Deploy Base Service

```bash
# Apply base Knative Service
kubectl apply -f deploy/base/knative-service.yaml -n {{ project_name }}

# Get service URL
kubectl get ksvc {{ project_name }} -n {{ project_name }}

# Test
export URL=$(kubectl get ksvc {{ project_name }} -n {{ project_name }} -o jsonpath='{.status.url}')
curl https://$URL/health/live
```

---

## FluxCD GitOps Deployment

GitOps manages infrastructure state via Git. FluxCD syncs manifests to the cluster.

### Repository Structure

```
your-repo/
├── clusters/
│   └── production/
│       ├── flux-system/
│       │   ├── gotk-components.yaml
│       │   └── kustomization.yaml
│       └── {{ project_name }}/
│           ├── kustomization.yaml
│           └── apps.yaml
├── deploy/
│   ├── base/
│   ├── overlays/
│   └── flux/
│       ├── git-repository.yaml
│       ├── kustomization.yaml
│       └── image-repository.yaml
```

### Step 1: Create GitRepository

```bash
# Create GitRepository source
kubectl apply -f deploy/flux/git-repository.yaml -n {{ project_name }}
```

`deploy/flux/git-repository.yaml`:
```yaml
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: GitRepository
metadata:
  name: {{ project_name }}
  namespace: {{ project_name }}
spec:
  interval: 1m
  url: https://github.com/{{ github_org }}/{{ github_repo }}
  ref:
    branch: {{ default_branch }}
  secretRef:
    name: github-token
```

### Step 2: Create Kustomization

```bash
# Create Kustomization
kubectl apply -f deploy/flux/kustomization.yaml -n {{ project_name }}
```

`deploy/flux/kustomization.yaml`:
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1beta2
kind: Kustomization
metadata:
  name: {{ project_name }}
  namespace: {{ project_name }}
spec:
  interval: 5m
  sourceRef:
    kind: GitRepository
    name: {{ project_name }}
  path: ./deploy/overlays/prod
  prune: true
  timeout: 2m
```

### Step 3: Enable Image Automation

Automatically update image references when new images are pushed:

```yaml
# deploy/flux/image-repository.yaml
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageRepository
metadata:
  name: {{ project_name }}
  namespace: {{ project_name }}
spec:
   image: {{ image_registry }}/{{ github_org }}/{{ project_name }}
  interval: 5m
  secretRef:
    name: registry-credentials

# deploy/flux/image-policy.yaml
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: {{ project_name }}
  namespace: {{ project_name }}
spec:
  imageRepositoryRef:
    name: {{ project_name }}
  policy:
    semver:
      range: ">=1.0.0"
```

### Step 4: Apply Deployment

```bash
# Create FluxCD resources
kubectl apply -k deploy/flux

# Sync FluxCD
flux reconcile source git flux-system

# Verify sync
flux get kustomizations --watch
```

---

## Environment-Specific Deployment

### Development

```bash
# Deploy to development namespace
kubectl apply -k deploy/overlays/dev -n {{ project_name }}-dev

# Configuration:
# - Min 1 replica (no scale-to-zero)
# - Debug logging
# - MinIO for storage
{% if feature_s3 %}# - Lower resource limits{% endif %}
```

`deploy/overlays/dev/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: {{ project_name }}-dev
resources:
  - ../../base

patchesStrategicMerge:
- |-
  apiVersion: serving.knative.dev/v1
  kind: Service
  metadata:
    name: {{ project_name }}
  spec:
    template:
      metadata:
        annotations:
          autoscaling.knative.dev/minScale: "1"
          autoscaling.knative.dev/maxScale: "10"
          autoscaling.knative.dev/target: "10"
      spec:
        containerConcurrency: 10
```

### Staging

```bash
# Deploy to staging namespace
kubectl apply -k deploy/overlays/staging -n {{ project_name }}-staging

# Configuration:
# - 2-20 replicas
# - Info logging
# - AWS S3 storage
# - Higher resource limits
```

`deploy/overlays/staging/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: {{ project_name }}-staging
resources:
  - ../../base

patches:
- patch: |-
    apiVersion: serving.knative.dev/v1
    kind: Service
    metadata:
      name: {{ project_name }}
    spec:
      template:
        metadata:
          annotations:
            autoscaling.knative.dev/minScale: "2"
            autoscaling.knative.dev/maxScale: "20"
            autoscaling.knative.dev/targetUtilizationPercentage: "70"
        spec:
          template:
            spec:
              containers:
              - name: user-container
                env:
                - name: APP__TELEMETRY__LOG_LEVEL
                  value: "info"
                - name: APP_ENV
                  value: "staging"
  target:
    kind: Service
    name: {{ project_name }}
```

### Production

```bash
# Deploy to production namespace
kubectl apply -k deploy/overlays/prod -n {{ project_name }}-prod

# Configuration:
# - 5-100 replicas
# - Warn logging
# - AWS S3 with high availability
# - Production secrets via External Secrets
```

`deploy/overlays/prod/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: {{ project_name }}-prod
resources:
  - ../../base

patches:
- patch: |-
    apiVersion: serving.knative.dev/v1
    kind: Service
    metadata:
      name: {{ project_name }}
    spec:
      template:
        metadata:
          annotations:
            autoscaling.knative.dev/minScale: "5"
            autoscaling.knative.dev/maxScale: "100"
            autoscaling.knative.dev/targetUtilizationPercentage: "80"
        spec:
          template:
            spec:
              containers:
              - name: user-container
                env:
                - name: APP__TELEMETRY__LOG_LEVEL
                  value: "warn"
                - name: APP_ENV
                  value: "production"
                resources:
                  limits:
                    memory: "1Gi"
                    cpu: "1000m"
                  requests:
                    memory: "512Mi"
                    cpu: "500m"
  target:
    kind: Service
    name: {{ project_name }}

secretGenerator:
- name: {{ project_name }}-secrets
  envs:
  - .env.production
```

---

## Rollback Procedures

### Option 1: Manual Revision Rollback

```bash
# List revisions
kubectl revisions list -n {{ project_name }}

# Rollback to previous revision
kubectl rollout undo service/{{ project_name }} -n {{ project_name }}

# Rollback to specific revision
kubectl set traffic {{ project_name }} \
  --revision={{ project_name }}-00001 \
  --percent=100 \
  -n {{ project_name }}
```

### Option 2: Git Rollback (GitOps)

```bash
# Revert commit
git revert <commit-hash>

# Push to trigger FluxCD sync
git push origin main

# Verify new revision deployed
flux get kustomizations -n {{ project_name }}
```

### Option 3: Canary Rollback

If using canary deployment:

```bash
# Shift all traffic back to stable
kubectl set traffic {{ project_name }} \
  --revision={{ project_name }}-stable \
  --percent=100 \
  -n {{ project_name }}
```

---

## Traffic Splitting

Knative supports traffic splitting between revisions for canary deployments.

### Example: 10% Traffic to New Version

```bash
# Deploy new version
kubectl set image service/{{ project_name }} \
  user-container={{ image_registry }}/{{ github_org }}/{{ project_name }}:v2.0.0 \
  -n {{ project_name }}

# Split traffic: 90% v1, 10% v2
kubectl set traffic {{ project_name }} \
  --revision={{ project_name }}-00001=90 \
  --revision={{ project_name }}-00002=10 \
  -n {{ project_name }}

# Monitor traffic split
kubectl describe ksvc {{ project_name }} -n {{ project_name }}
```

### Gradual Rollout

```bash
# 10%
kubectl set traffic {{ project_name }} \
  --revision={{ project_name }}-00001=90 \
  --revision={{ project_name }}-00002=10

# Wait and monitor (e.g., check error rates in Prometheus)
# Then increase to 25%
kubectl set traffic {{ project_name }} \
  --revision={{ project_name }}-00001=75 \
  --revision={{ project_name }}-00002=25

# 50%
kubectl set traffic {{ project_name }} \
  --revision={{ project_name }}-00001=50 \
  --revision={{ project_name }}-00002=50

# 100% to new version
kubectl set traffic {{ project_name }} \
  --revision={{ project_name }}-00002=100
```

### Blue-Green Deployment

```bash
# Create blue (current) revision
kubectl set traffic {{ project_name }} \
  --revision={{ project_name }}-00001=100

# Deploy green (new) revision
kubectl apply -f deploy/overlays/prod -n {{ project_name }}

# Shift all traffic to green
kubectl set traffic {{ project_name }} \
  --revision={{ project_name }}-00002=100

# Keep blue for rollback
# Delete blue later after verification
```

---

## Monitoring Deployments

### Check Service Status

```bash
# Get service URL
kubectl get ksvc {{ project_name }} -n {{ project_name }}

# Get service details
kubectl describe ksvc {{ project_name }} -n {{ project_name }}

# Get pods
kubectl get pods -n {{ project_name }} -l serving.knative.dev/service={{ project_name }}

# Get revisions
kubectl revisions list -n {{ project_name }}
```

### Check FluxCD Status

```bash
# Get FluxCD sources
flux get sources git -n {{ project_name }}

# Get FluxCD kustomizations
flux get kustomizations -n {{ project_name }}

# Sync manually
flux reconcile kustomization {{ project_name }} -n {{ project_name }}

# Get conditions
flux get kustomizations -n {{ project_name }} --watch
```

### View Logs

```bash
# Service logs
kubectl logs -f -n {{ project_name }} deployment/{{ project_name }}

# Specific pod
kubectl logs -f -n {{ project_name }} <pod-name>

# Previous revision logs
kubectl logs -f -n {{ project_name }} deployment/{{ project_name }} --previous

# Knative serving logs
kubectl logs -n knative-serving deployment/controller
kubectl logs -n knative-serving deployment/autoscaler
```

---

## CI/CD Pipeline

### GitHub Actions Example

`.github/workflows/deploy.yaml`:
```yaml
name: Deploy

on:
  push:
    branches: [main]

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4

    - name: Build Docker image
      run: docker build -t ${{ secrets.REGISTRY }}/{{ project_name }}:${{ github.sha }} .

    - name: Login to registry
      run: echo ${{ secrets.REGISTRY_PASSWORD }} | docker login -u ${{ secrets.REGISTRY_USER }} --password-stdin ${{ secrets.REGISTRY }}

    - name: Push image
      run: docker push ${{ secrets.REGISTRY }}/{{ project_name }}:${{ github.sha }}

    - name: Tag as latest
      run: docker tag ${{ secrets.REGISTRY }}/{{ project_name }}:${{ github.sha }} ${{ secrets.REGISTRY }}/{{ project_name }}:latest && docker push ${{ secrets.REGISTRY }}/{{ project_name }}:latest

  deploy-staging:
    needs: build-and-push
    runs-on: ubuntu-latest
    environment: staging
    steps:
    - name: Deploy to staging
      run: |
        flux reconcile kustomization {{ project_name }}-staging \
          --with-source=false \
          --namespace {{ project_name }}-staging

  deploy-production:
    needs: build-and-push
    runs-on: ubuntu-latest
    environment: production
    steps:
    - name: Deploy to production
      run: |
        flux reconcile kustomization {{ project_name }}-prod \
          --with-source=false \
          --namespace {{ project_name }}-prod
```

---

## Troubleshooting Deployments

### Service Not Ready

```bash
# Describe service
kubectl describe ksvc {{ project_name }} -n {{ project_name }}

# Check conditions
kubectl get ksvc {{ project_name }} -n {{ project_name }} -o jsonpath='{.status.conditions[*]}' | jq

# Common issues:
# - ImagePullBackOff: Check image registry credentials
# - CrashLoopBackOff: Check application logs
# - ConfigMissing: Check ConfigMaps and Secrets exist
```

### Pods Not Starting

```bash
# Check pod status
kubectl get pods -n {{ project_name }}

# Get pod events
kubectl describe pod <pod-name> -n {{ project_name }}

# Check pod logs
kubectl logs <pod-name> -n {{ project_name }}

# Common issues:
# - OOMKilled: Increase memory limits
# - FailedScheduling: Check node resources
# - ContainerCreating: Check image pull progress
```

### FluxCD Not Syncing

```bash
# Get FluxCD logs
kubectl logs -n flux-system deployment/source-controller
kubectl logs -n flux-system deployment/kustomize-controller

# Check GitRepository status
kubectl get gitrepository -n {{ project_name }}

# Check Kustomization status
kubectl get kustomization -n {{ project_name }}

# Reconcile manually
flux reconcile source git flux-system
flux reconcile kustomization {{ project_name }} -n {{ project_name }}
```

---

## Security Best Practices

1. **Use Secrets for Credentials**:
   ```yaml
   env:
   - name: AWS_ACCESS_KEY_ID
     valueFrom:
       secretKeyRef:
         name: {{ project_name }}-secrets
         key: aws-access-key-id
   ```

2. **Enable RBAC**:
   ```yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: {{ project_name }}
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   rules:
   - apiGroups: [""]
     resources: ["configmaps", "secrets"]
     verbs: ["get", "list"]
   ```

3. **Network Policies**:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: {{ project_name }}
   spec:
     podSelector:
       matchLabels:
         serving.knative.dev/service: {{ project_name }}
     policyTypes:
     - Ingress
     - Egress
   ```

4. **Image Vulnerability Scanning**:
   ```yaml
   - name: Run Trivy
     run: trivy image --severity HIGH,CRITICAL ${{ secrets.REGISTRY }}/{{ project_name }}:${{ github.sha }}
   ```

See `docs/SECURITY.md` for complete security guidance.

---

## Next Steps

- **Configuration**: See `docs/CONFIGURATION.md` for environment-specific config
- **Monitoring**: See `docs/MONITORING.md` for observability
- **Troubleshooting**: See `docs/TROUBLESHOOTING.md` for deployment issues
- **Security**: See `docs/SECURITY.md` for hardening
