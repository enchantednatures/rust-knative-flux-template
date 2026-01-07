# FluxCD Integration Guide for PostgreSQL Feature

This guide documents how the PostgreSQL backup feature integrates with FluxCD for GitOps-based deployment and management.

## Architecture Overview

The PostgreSQL feature uses FluxCD to manage:

1. **GitRepository Source** (`git-repository-postgres.yaml`)
   - Points to the repository branch with PostgreSQL manifests
   - Reconciles every 5 minutes for config changes

2. **Kustomization Resources** (`postgres-kustomization.yaml.liquid`)
   - Deploys CloudNativePG clusters via kustomize overlays
   - Manages environment-specific configurations (dev/staging/prod)
   - Handles secret decryption with SOPS

3. **Operator Dependencies**
   - Waits for CloudNativePG operator to be ready before deploying clusters
   - Ensures correct installation order in ClusterBootstrapOrder

## FluxCD Resources

### GitRepository: rust-service-postgres

**File**: `deploy/flux/git-repository-postgres.yaml`

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: rust-service-postgres
  namespace: flux-system
spec:
  interval: 5m  # Check for updates every 5 minutes
  url: https://github.com/test-org/test-repo
  ref:
    branch: 001-cloudnative-postgres-backups  # PostgreSQL feature branch
```

**Purpose**:
- Tracks the `001-cloudnative-postgres-backups` branch
- Provides source for Kustomization resources
- Watches for configuration changes and updates

**Configuration**:
- `interval: 5m` - Reconciliation frequency
- `url` - Repository URL (template variable)
- `ref.branch` - Specific branch with PostgreSQL feature
- Optional: `secretRef` for private repositories

### Kustomization: postgres-infrastructure

**File**: `deploy/flux/postgres-kustomization.yaml.liquid`

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: postgres-infrastructure
  namespace: flux-system
spec:
  interval: 5m  # Check for updates every 5 minutes
  path: ./deploy/overlays/dev  # Path to kustomize overlay
  prune: true  # Remove resources not in manifest
  sourceRef:
    kind: GitRepository
    name: test-repo-postgres
  wait: true  # Wait for resources to become healthy
  timeout: 10m  # Timeout for deployment
  
  # Wait for CloudNativePG operator first
  dependsOn:
    - name: cnpg-operator
  
  # Decrypt SOPS-encrypted secrets
  decryption:
    provider: sops
    secretRef:
      name: sops-age
  
  # Health checks for deployed resources
  healthChecks:
    - apiVersion: postgresql.cnpg.io/v1
      kind: Cluster
      name: test-app-postgres
      namespace: default
  
  # Post-build substitutions
  postBuild:
    substitute:
      POSTGRES_APP_NAME: "test-app-postgres"
```

**Features**:

#### Operator Dependency Management
```yaml
dependsOn:
  - name: cnpg-operator  # Wait for CloudNativePG operator
```
- Ensures CloudNativePG operator is deployed before PostgreSQL clusters
- Prevents race conditions during cluster initialization
- Part of Flux dependency chain: infrastructure → operator → cluster

#### Secret Decryption (SOPS)
```yaml
decryption:
  provider: sops
  secretRef:
    name: sops-age
```
- Decrypts object storage credentials automatically
- Uses Age encryption (modern alternative to GPG)
- Secrets must be encrypted with SOPS before committing

#### Health Checks
```yaml
healthChecks:
  - apiVersion: postgresql.cnpg.io/v1
    kind: Cluster
    name: test-app-postgres
```
- Validates cluster reaches healthy state
- Flux won't consider deployment successful until health checks pass
- Prevents cascading failures from unhealthy clusters

## Deployment Flow

### 1. Initial Setup

```bash
# Bootstrap FluxCD (usually done once per cluster)
flux bootstrap github \
  --owner=<github_org> \
  --repo=<github_repo> \
  --branch=main \
  --path=clusters/my-cluster

# Enable postgres feature in cargo-generate
cargo generate --path . \
  --define postgres_feature=true \
  --define github_org=<your_org> \
  --define github_repo=<your_repo>
```

### 2. GitOps Workflow

```
Developer Push → GitHub → Flux Reconciliation → Cluster Update
```

**Step 1**: Developer commits PostgreSQL configuration to `001-cloudnative-postgres-backups` branch
```bash
git add deploy/overlays/dev/postgres-*.yaml.liquid
git commit -m "Update PostgreSQL cluster configuration"
git push origin 001-cloudnative-postgres-backups
```

**Step 2**: GitRepository source detects changes (within 5 minutes)
```bash
flux get sources git
# NAME                   READY   MESSAGE
# rust-service-postgres  True    Fetched revision
```

**Step 3**: Kustomization reconciles and applies changes
```bash
flux get kustomizations
# NAME                    READY   STATUS
# postgres-infrastructure True    Applied revision
```

**Step 4**: CloudNativePG operator deploys new cluster
```bash
kubectl get cluster
# NAME                      STATUS   AGE
# rust-service-postgres     Cluster in healthy state   2m
```

### 3. Monitoring Reconciliation

```bash
# Watch GitRepository sync
flux get sources git --watch

# Watch Kustomization apply
flux get kustomizations --watch

# View reconciliation logs
flux logs --kind=GitRepository --name=rust-service-postgres
flux logs --kind=Kustomization --name=postgres-infrastructure
```

## Multi-Environment Deployment

### Environment Overlays

The PostgreSQL feature supports three environments via separate Kustomization resources:

#### Development (dev)
```yaml
# deploy/flux/postgres-kustomization.yaml.liquid
spec:
  path: ./deploy/overlays/dev  # Uses dev overlay
  interval: 5m  # More frequent updates
```
- 1 instance for cost savings
- Async replication
- MinIO for object storage
- 7-day backup retention

#### Staging (staging)
```yaml
spec:
  path: ./deploy/overlays/staging  # Uses staging overlay
  dependsOn:
    - name: postgres-infrastructure  # Depends on dev being ready first
```
- 2 instances for HA testing
- Async replication
- MinIO or S3 storage
- 14-day backup retention

#### Production (prod)
```yaml
spec:
  path: ./deploy/overlays/prod  # Uses prod overlay
  dependsOn:
    - name: postgres-infrastructure
  timeout: 20m  # Longer timeout for larger clusters
```
- 3 instances for high availability
- Quorum replication (zero data loss)
- AWS S3 for durability
- 30-day backup retention

### Parallel Environment Setup

Create separate Kustomization resources for each environment:

```bash
# clusters/my-cluster/postgres-dev.yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: postgres-dev
  namespace: flux-system
spec:
  path: ./deploy/overlays/dev
  sourceRef:
    kind: GitRepository
    name: rust-service-postgres

---
# clusters/my-cluster/postgres-prod.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: postgres-prod
  namespace: flux-system
spec:
  path: ./deploy/overlays/prod
  sourceRef:
    kind: GitRepository
    name: rust-service-postgres
```

## Secret Management (SOPS)

### Initial Setup

1. **Generate Age key**:
   ```bash
   age-keygen -o ~/.config/sops/age/keys.txt
   ```

2. **Create SOPS secret in cluster**:
   ```bash
   kubectl create secret generic sops-age \
     --from-file=age.agekey=$HOME/.config/sops/age/keys.txt \
     -n flux-system
   ```

3. **Create `.sops.yaml` in repo root**:
   ```yaml
   creation_rules:
     - path_regex: deploy/overlays/.*/.*.yaml
       encrypted_regex: '^(data|stringData)$'
       provider: age
       age: 'age1...'  # Your public age key
   ```

### Encrypting Secrets

```bash
# Create secret template
cat > deploy/overlays/dev/postgres-secret.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: postgres-backup-storage
  namespace: default
type: Opaque
stringData:
  ACCESS_KEY_ID: minioadmin
  ACCESS_SECRET_KEY: minioadmin
EOF

# Encrypt with SOPS
sops -e -i deploy/overlays/dev/postgres-secret.yaml

# Commit encrypted file
git add deploy/overlays/dev/postgres-secret.yaml
git commit -m "Add encrypted PostgreSQL backup credentials"
```

### Decryption During Deployment

Flux automatically decrypts when reconciling:

```yaml
spec:
  decryption:
    provider: sops
    secretRef:
      name: sops-age  # Flux uses this secret for decryption
```

## Troubleshooting

### GitRepository Sync Issues

**Problem**: GitRepository stuck in "Unknown" state

```bash
# Check GitRepository status
kubectl describe gitrepository rust-service-postgres -n flux-system

# Common causes:
# 1. Network issues - check connectivity to GitHub
# 2. Invalid credentials - check deploy key permissions
# 3. Branch doesn't exist - verify branch name

# Force reconciliation
flux reconcile source git rust-service-postgres
```

### Kustomization Apply Failures

**Problem**: Kustomization shows "False" ready status

```bash
# Check status details
kubectl describe kustomization postgres-infrastructure -n flux-system

# Check logs
flux logs --kind=Kustomization --name=postgres-infrastructure

# Common causes:
# 1. Operator not ready - check cnpg-operator dependency
# 2. Invalid manifests - check kustomize build output
# 3. Resource conflicts - check for duplicate resources

# Manual kustomize validation
kustomize build deploy/overlays/dev
```

### SOPS Decryption Issues

**Problem**: Secrets not being decrypted

```bash
# Check SOPS secret exists
kubectl get secret sops-age -n flux-system

# Verify Age key is valid
kubectl get secret sops-age -n flux-system \
  -o jsonpath='{.data.age\.agekey}' | base64 -d | head -1

# Check Kustomization decryption status
kubectl describe kustomization postgres-infrastructure -n flux-system | grep -A 5 "Decryption"

# Manually test decryption
kubectl exec -it [flux-helm-controller-pod] -n flux-system -- \
  sops -d deploy/overlays/dev/postgres-secret.yaml
```

### Dependency Chain Issues

**Problem**: Resources not deploying in correct order

```bash
# Check dependency chain
flux get kustomizations -A --tree

# Expected order:
# └── infrastructure-operator (CloudNativePG)
#     └── postgres-infrastructure (PostgreSQL clusters)

# Force dependency order
kubectl annotate kustomization postgres-infrastructure \
  kustomize.toolkit.fluxcd.io/depends-on=cnpg-operator:cnpg-system \
  --overwrite
```

## Best Practices

### 1. Git Workflow

```bash
# Create feature branch for PostgreSQL changes
git checkout -b feature/postgres-upgrade

# Make changes to overlay
# Commit changes
git add deploy/overlays/dev/postgres-cluster-patch.yaml
git commit -m "Update PostgreSQL cluster parameters"

# Create pull request
gh pr create --title "Update PostgreSQL configuration"

# After review and merge, feature branch auto-deploys
```

### 2. Testing Before Production

```bash
# Deploy to dev first
flux get kustomizations postgres-dev

# Wait for health checks to pass
kubectl wait --for=condition=ready cluster/myapp-postgres -n default --timeout=5m

# Validate in dev environment
# Then promote to prod
```

### 3. Monitoring and Alerts

```bash
# Flux exposes Prometheus metrics
kubectl port-forward -n flux-system svc/prometheus 9090:9090

# Query reconciliation status
# flux_reconcile_duration_seconds
# flux_reconcile_success
# flux_kustomization_info
```

### 4. Backup Strategy

```bash
# Always backup SOPS encryption keys
cp ~/.config/sops/age/keys.txt ~/backup/sops-age-keys.txt

# Test restoring from backup regularly
age-keygen -o /tmp/test-keys.txt < ~/backup/sops-age-keys.txt

# Rotate keys periodically
# Requires re-encrypting all secrets with new key
```

## Integration with CI/CD

### GitHub Actions Example

```yaml
name: PostgreSQL GitOps Validation

on:
  pull_request:
    paths:
      - 'deploy/overlays/*/postgres-*.yaml*'

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Install kustomize
        run: curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
      
      - name: Validate manifests
        run: |
          kustomize build deploy/overlays/dev
          kustomize build deploy/overlays/staging
          kustomize build deploy/overlays/prod
      
      - name: Check SOPS encryption
        run: |
          # Verify secret files are encrypted
          grep -r "ENC\[" deploy/overlays/*/postgres-secret.yaml
```

## References

- [Flux Documentation](https://fluxcd.io/docs/)
- [Kustomize Overlays](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/)
- [SOPS Documentation](https://github.com/mozilla/sops)
- [Age Encryption](https://github.com/FiloSottile/age)
- [CloudNativePG GitOps](https://cloudnative-pg.io/documentation/current/architecture/)
