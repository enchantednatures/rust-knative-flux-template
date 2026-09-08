# Deployment Guide

Complete guide for deploying {{ project_name }} to Kubernetes using Knative Serving and FluxCD GitOps.

> **About Template Variables**: This is a template file that uses Liquid syntax for variables like `{{ project_name }}`. During project generation with `cargo-generate`, these placeholders are replaced with your actual project values. The generated documentation will contain your specific project name instead of the template variable.

## About Project Naming

### Template Variable: `project_name`

When generating a project from this template, you'll be prompted for a `project_name`. This name is automatically normalized to follow platform-specific conventions:

- **Kubernetes Resources** (Knative Services, ConfigMaps, Secrets): Uses **kebab-case** (hyphens)
  - Example: `my-service`, `user-api`, `payment-processor`
  - Kubernetes DNS names require hyphens, not underscores
  
- **Rust Crate** (Cargo.toml): Uses **snake_case** (underscores)
  - Example: `my_service`, `user_api`, `payment_processor`
  - Rust convention for package names

- **Docker Images**: Uses **kebab-case** (hyphens) to match Kubernetes names
  - Example: `ghcr.io/org/my-service:latest`

**What You Input**: When running `cargo generate`, you can provide `project_name` in any format:
- `my-service` (hyphens)
- `my_service` (underscores)  
- `myservice` (single word)

**Template Normalization**: The template automatically converts your input:
- `{{ project_name | replace: "_", "-" }}` → Forces kebab-case for Kubernetes/Docker
- `{{ crate_name }}` → Automatically converted to snake_case for Rust

**Why This Matters**: Knative Services **cannot** contain underscores in their names. Using underscores will cause `ImagePullBackOff` errors because the image tag won't match the service name. The template handles this normalization automatically.

> **For Detailed Information**: See the "Naming Conventions" section in [`../AGENTS.md`](../AGENTS.md) for comprehensive documentation on how naming works across all template files, common issues, and solutions.

## Table of Contents

- [About Project Naming](#about-project-naming)
- [Prerequisites](#prerequisites)
- [Local Testing](#local-testing)
- [Manual Kubernetes Deployment](#manual-kubernetes-deployment)
- [FluxCD GitOps Deployment](#fluxcd-gitops-deployment)
- [Environment-Specific Deployment](#environment-specific-deployment)
- [Production Deployment](#production-deployment)
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
# Apply the base HelmRelease (Flux renders the Knative Service via deploy/chart)
kubectl apply -k deploy/base -n {{ project_name }}

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
# Bootstrap Flux to track this repo + deploy to production
make bootstrap production
```

Or apply manually per environment:

```bash
kubectl apply -f deploy/flux/kustomization-prod.yaml
```

`deploy/flux/kustomization-prod.yaml`:
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

# Alternative: Use the 'release' tag for stable deployments
# This tag is automatically applied by the release workflow
# deploy/flux/image-policy-release.yaml
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: {{ project_name }}-release
  namespace: {{ project_name }}
spec:
  imageRepositoryRef:
    name: {{ project_name }}
  filterTags:
    pattern: '^release$'
  policy:
    alphabetical:
      order: asc
```

**Image Policy Options:**

1. **SHA-based (Continuous Deployment)**: Automatically deploy every commit to main
   - Pattern: `sha-[a-f0-9]{7}`
   - Use case: Dev/staging environments
   - Pros: Immediate feedback, automated
   - Cons: May deploy broken builds

2. **Release tag (Stable Deployment)**: Deploy only when you create a release
   - Pattern: `release`
   - Use case: Production environments
   - Pros: Controlled, stable, tested
   - Cons: Manual release process

3. **SemVer (Version-based)**: Deploy specific semantic versions
   - Pattern: Semver range (e.g., `>=1.0.0`)
   - Use case: Production with version control
   - Pros: Explicit versioning, rollback-friendly
   - Cons: Requires version management

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

## Production Deployment

The template ships a one-command production deploy flow: `make prod-deploy` drives FluxCD end to end (GitRepository source, deploy-key auto-detection, prod Flux config, reconciliation waits, Knative service readiness, in-cluster health smoke suite). The same flow also runs from GitHub Actions on a protected `production` environment. This section covers that flow only; the sections above describe the underlying GitOps pieces in detail.

> **Relationship to `flux bootstrap github`**: The [Install FluxCD](#install-fluxcd) section above shows `flux bootstrap github`, the alternative path for installing Flux on a cluster in the first place. The two complement each other: bootstrap installs Flux itself, while `make prod-deploy` deploys this service through an already-running Flux.

### Prerequisites

- A production cluster with **FluxCD** and **Knative Serving** installed cluster-wide (see [Install Knative Serving](#install-knative-serving) and [Install FluxCD](#install-fluxcd)). If Flagger is enabled, it must be installed cluster-wide too; `prod-deploy` fails fast if its canary dependency is missing and never installs operators itself.
- Local tooling: `kubectl`, the `flux` CLI, and `gh` (GitHub CLI, only needed for the one-time `make prod-github-env` setup).
- Kubeconfig access to the production cluster, either via the `KUBECONFIG` environment variable or a `.kubeconfig-prod` file in the repo root (see [Kubeconfig Options](#kubeconfig-options)).

### One-Time Setup

1. **Create the GitHub `production` environment** (run locally; CI tokens cannot create environments):

   ```bash
   make prod-github-env
   ```

   This creates the `production` environment with deployment branch policies for `main` and `v*` tags, using `gh api`. It is idempotent (existing environment and policies are left as-is) and supports `--dry-run` via `./scripts/prod/create-github-env.sh --dry-run`.

2. **Run the deploy key flow**:

   ```bash
   make prod-deploy
   ```

   The **first run fails by design**. It applies the GitRepository (SSH URL, `secretRef: github-deploy-key`), detects the resulting auth failure, creates the `github-deploy-key` SSH secret in `flux-system` (`flux create secret git`), and prints the **public key** plus exact instructions:

   - Add the key on GitHub: **Repo → Settings → Deploy keys → Add deploy key**.
   - Check **"Allow write access"** only if the project was generated with `enable_image_updates`. ImageUpdateAutomation commits image tag bumps back to the repo, so it needs write access; plain deploys work with a read-only deploy key (the default).
   - The script polls non-interactively (up to ~5 minutes) while you add the key, then exits non-zero if the GitRepository is still not Ready.

   Run `make prod-deploy` a second time and it succeeds: the secret already exists, the script prints its existing public key instead of recreating it, and reconciliation proceeds. The script **never rotates** an existing `github-deploy-key` secret, so re-runs are always safe.

### Usage

**Local deploy** (kubeconfig required, see below):

```bash
make prod-deploy                       # full deploy + in-cluster smoke suite
./scripts/prod/deploy.sh --dry-run     # print the full 9-step plan, touch nothing
```

**GitHub Actions deploy** (after the one-time setup above):

- Push a `v*` tag: `git tag v1.0.0 && git push origin v1.0.0`, or
- Use **workflow_dispatch** from the Actions UI ("Deploy Production" → Run workflow).

The job runs in the protected `production` environment, gated by the `main` + `v*` branch policies created during setup.

> **Deploy semantics: a tag does NOT pin the deployed ref.** Flux tracks the default branch (`deploy/flux/git-repository.yaml` sets `ref.branch` to the default branch). A `v*` tag push triggers the workflow, but what gets deployed is the current default-branch ref plus whatever image tag the ImagePolicy has selected. Tags decide *when* to deploy, not *which ref* to deploy.

### Kubeconfig Options

| Path | How | Used by |
|------|-----|---------|
| `KUBECONFIG` env var | `export KUBECONFIG=$PWD/.kubeconfig-prod` (see `make prod-kubeconfig`) | local runs, non-ARC GHA path |
| `.kubeconfig-prod` file | place at repo root (gitignored); resolved when `KUBECONFIG` is unset | local runs |
| In-cluster ServiceAccount | nothing to configure | ARC runner path (`feature_gha_runner` on) |

The non-ARC workflow path (project generated without `feature_gha_runner`) needs the `PROD_KUBECONFIG` Actions secret set on the `production` environment; the workflow writes it to a 0600 file and exports `KUBECONFIG` before calling `make prod-deploy`. The ARC runner path needs neither the env var nor the file: the runner pod authenticates with its in-cluster ServiceAccount.

### Runner RBAC Scope

When `feature_gha_runner` is on, the ARC runner pod runs as a dedicated ServiceAccount (`{{ project_name | replace: "_", "-" }}-runner` in `actions-runner-system`) with namespace-scoped Roles only: `flux-system` (Flux reconciliation objects, plus read/create on the `github-deploy-key` secret for deploy-key auto-creation) and `production` (Knative service reads, smoke-test pod lifecycle, pod logs, events). There is no cluster-wide RBAC.

> **Security note**: Because of that scope, the runner ServiceAccount can read the `github-deploy-key` secret in `flux-system`. For a per-repo runner whose only job is deploying this repo, this is the minimum access that makes CI-side deploy-key auto-creation work. Runner pods are short-lived (scale-to-zero), so the access exists only while a job runs.

### Rollback

Rollback is a git operation: revert the offending commit (or revert the image reference bump) on the default branch and push. Flux reconciles the reverted state and Knative creates a new revision from it; see [Rollback Procedures](#rollback-procedures) for manual traffic tricks. No rollback tooling is built into `prod-deploy`, and the script never mutates workloads directly (it applies only Flux config objects), so the cluster always converges to whatever git says.

### Smoke Suite

`make prod-deploy` ends with an in-cluster smoke suite: one detached `curlimages/curl` pod per check, so results do not depend on ingress reachability from your workstation. Each curl gets a 60-second max time to absorb a scale-to-zero cold start. The four checks:

| Endpoint | Expected |
|----------|----------|
| `/health/live` | HTTP 200, body contains `{"status":"alive"}` |
| `/health/ready` | HTTP 200, body contains `{"status":"ready"}` |
| `/metrics` | HTTP 200, body contains `# HELP` |
| `/api/v1/hello` | HTTP 200, body contains `message` |

Any failed check prints the pod logs as diagnostics and makes the deploy exit non-zero.

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

### Continuous Integration (CI)

The CI workflow runs on every push to main and on pull requests:

```yaml
# .github/workflows/ci.yaml
name: CI/CD Pipeline

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: Install Rust
        uses: dtolnay/rust-toolchain@stable
      - name: Run Clippy
        run: cargo clippy --all-targets -- -D warnings
  
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: Run tests
        run: cargo test --all-features
  
  build:
    needs: [lint, test]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: Build and push Docker image
        uses: docker/build-push-action@v6
        with:
          push: true
          tags: |
            ${{ env.REGISTRY }}/${{ github.repository }}:sha-${{ github.sha }}
            ${{ env.REGISTRY }}/${{ github.repository }}:latest
```

### Release Workflow

The release workflow is triggered when you push a Git tag (e.g., `v1.0.0`):

```yaml
# .github/workflows/release.yaml
name: Release

on:
  push:
    tags:
      - 'v*'

jobs:
  create-release:
    runs-on: ubuntu-latest
    steps:
      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ github.ref }}
          name: Release ${{ github.ref }}
  
  build-release:
    needs: create-release
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: Build and push release image
        uses: docker/build-push-action@v6
        with:
          push: true
          tags: |
            ${{ env.REGISTRY }}/${{ github.repository }}:${{ github.ref_name }}
            ${{ env.REGISTRY }}/${{ github.repository }}:release
          build-args: |
            RUST_BASE_IMAGE_TAG=release
```

**Creating a Release:**

```bash
# Tag your commit
git tag -a v1.0.0 -m "Release version 1.0.0"

# Push the tag to trigger the release workflow
git push origin v1.0.0

# The release workflow will:
# 1. Create a GitHub release
# 2. Build a Docker image with Rust 'release' base image if available
# 3. Tag the image with version (1.0.0) and 'release'
# 4. Run security scans
```

**Base Image Policy:**

The release workflow uses a policy-driven approach for selecting Rust base images:

- **Development builds**: Use versioned Rust image (e.g., `rust:1.92-slim`)
- **Release builds**: Prefer `rust:release` tag if available, otherwise fall back to versioned tag
- **Benefits**: 
  - Stable, tested Rust versions for releases
  - Reproducible builds across environments
  - Security patches applied to release images

### FluxCD Integration

Once images are pushed, FluxCD can automatically deploy them based on your ImagePolicy:

```bash
# Deploy using the 'release' tag (recommended for production)
kubectl apply -f - <<EOF
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: {{ project_name }}-release
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: {{ project_name }}
  filterTags:
    pattern: '^release$'
EOF

# Deploy using semver (alternative for version-controlled deployments)
kubectl apply -f - <<EOF
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: {{ project_name }}-semver
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: {{ project_name }}
  policy:
    semver:
      range: ">=1.0.0"
EOF
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
