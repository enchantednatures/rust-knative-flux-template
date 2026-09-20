# FluxCD Integration Guide for PostgreSQL Feature

This guide documents how the PostgreSQL feature integrates with FluxCD for GitOps-based deployment and management.

## Architecture Overview

The PostgreSQL feature uses FluxCD to manage:

1. **Operator install (cluster-wide)** (`deploy/flux/cnpg-operator-kustomization.yaml`)
   - Flux Kustomization `cnpg-operator` in `flux-system`
   - Renders `deploy/infrastructure/cnpg-operator/` — CloudNativePG operator 1.28.0 + Barman Cloud Plugin v0.11.0 remote manifests into the `cnpg-system` namespace
   - Included from `deploy/flux/config/{dev,staging,prod}/kustomization.yaml`, gated by the `feature_postgres` flag

2. **Per-environment app Kustomizations** (`deploy/flux/kustomization-{dev,staging,prod}.yaml`)
   - Each environment's existing Kustomization now carries, gated by `feature_postgres`:
     - `dependsOn: [{name: cnpg-operator}]` so CNPG CRDs exist before the component applies
     - `healthChecks` on `Cluster/{{ project_name | replace: "_", "-" }}-postgres` in the env namespace (`default` / `staging` / `production`)
     - `decryption` (SOPS: provider `sops`, secretRef `sops-age`) so the SOPS-encrypted backup storage secret can live inside the overlay

3. **PostgreSQL component** (`deploy/components/postgres/` — Kustomize Component)
   - Included from each environment overlay (`deploy/overlays/{env}/kustomization.yaml`)
   - Carries the `Cluster`, `ObjectStore`, and `ScheduledBackup` resources
   - Per-env deltas applied via JSON6902 patches in the overlays (instances, backup retention)

The standalone `deploy/flux/postgres-kustomization.yaml` from earlier drafts was removed: resources flow through the per-env app Kustomization so the overlay's `namespace:` transformer places everything in the right namespace and reconciliation pins to the same revision as the application.

## FluxCD Resources

### GitRepository (shared)

**File**: `deploy/flux/git-repository.yaml`

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: {{ project_name | replace: "_", "-" }}
  namespace: flux-system
spec:
  interval: 1m
  url: https://github.com/{{ github_org }}/{{ github_repo }}
  ref:
    branch: {{ default_branch }}
```

One shared GitRepository serves the operator Kustomization and every app Kustomization; there is no postgres-specific source.

### Operator Kustomization: cnpg-operator

**File**: `deploy/flux/cnpg-operator-kustomization.yaml`

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cnpg-operator
  namespace: flux-system
spec:
  interval: 10m
  path: ./deploy/infrastructure/cnpg-operator
  prune: true
  sourceRef:
    kind: GitRepository
    name: {{ project_name | replace: "_", "-" }}
  wait: true
  timeout: 15m
```

### App Kustomization (per env)

**File**: `deploy/flux/kustomization-dev.yaml` (staging/prod identical except `path` and the healthCheck namespace)

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: {{ project_name | replace: "_", "-" }}-dev
  namespace: flux-system
spec:
  interval: 10m
  path: ./deploy/overlays/dev
  prune: true
  sourceRef:
    kind: GitRepository
    name: {{ project_name | replace: "_", "-" }}
  wait: true
  timeout: 5m
  {%- if feature_flagger or feature_postgres %}
  dependsOn:
    {%- if feature_flagger %}
    - name: flagger
    {%- endif %}
    {%- if feature_postgres %}
    - name: cnpg-operator
    {%- endif %}
  {%- endif %}
  {%- if feature_postgres %}
  healthChecks:
    - apiVersion: postgresql.cnpg.io/v1
      kind: Cluster
      name: "{{ project_name | replace: '_', '-' }}-postgres"
      namespace: default
  decryption:
    provider: sops
    secretRef:
      name: sops-age
  {%- endif %}
```

**Why decryption lives here**: the Kustomization reconciles the overlay containing the postgres component plus (once you add it) the SOPS-encrypted `object-storage-secret.yaml`. Files without a SOPS header pass through untouched, so decryption is safe for the whole overlay.

## Deployment Flow

### 1. Initial Setup

```bash
# Requires the SOPS age key so decryption succeeds on every pull
kubectl create secret generic sops-age -n flux-system \
  --from-file=age.agekey=./sops.key
# Bootstrap the environment
make bootstrap dev
```

### 2. GitOps Workflow

```bash
flux get sources git -A                  # GitRepository ready
flux get kustomizations                  # cnpg-operator applied, then the app kustomization
kubectl get cluster -A                   # Cluster in healthy state
flux logs --all-namespaces --level=error
```

Ordering: Flux applies `cnpg-operator` first (its `wait: true` blocks on the operator Deployment). The environment's app Kustomization then applies the overlay — where the postgres component needs the CRDs the operator installs.

### 3. Environment Overlays

Each overlay:

1. Includes the postgres component (`components:` entry gated by `feature_postgres`) — the overlay's `namespace:` transformer places `Cluster`/`ObjectStore`/`ScheduledBackup` into `default`/`staging`/`production`.
2. JSON6902 patches per env (each gated by `feature_postgres`):
   - `Cluster /spec/instances` — `{{ postgres_instances_dev }}` /`{{ postgres_instances_staging }}` / `{{ postgres_instances_prod }}`
   - `ObjectStore /spec/retentionPolicy` — `{{ backup_retention_dev }}d` / `{{ backup_retention_staging }}d` / `{{ backup_retention_prod }}d`
3. App values patched via the HelmRelease strategic merge in `deploy/base/helmrelease.yaml` (image, scaling, gated `APP__POSTGRES__URL` env + CA volume).

> **Known limitation**: overlays contain the empty-string `services.""` HelmRelease patch, which kustomize >= 5.4 rejects ("wrong node kind: expected ScalarNode but got MappingNode"). Pre-existing tracked issue #136, not specific to postgres resources.

## Multi-Environment Deployment

| Environment | app Kustomization | Overlay namespace | Instances | Retention | Backup destination |
|-------------|-------------------|-------------------|-----------|-----------|--------------------|
| dev | `<project>-dev` | `default` | 1 | 7d | MinIO (`minio.minio.svc.cluster.local:9000`) |
| staging | `<project>-staging` | `staging` | 2 (patched) | 14d | real S3 (patch `ObjectStore /spec/configuration/endpointURL`) |
| production | `<project>-prod` | `production` | 3 | 30d | real S3 (patch endpoint per env) |

Bootstrap the matching config (`make bootstrap dev|staging|prod`). All three environments reconcile the cluster-wide operator cleanly when `feature_postgres` is enabled at generate time.

## Troubleshooting

```bash
# Operator not ready
kubectl -n cnpg-system logs deploy/cnpg-controller-manager --tail=100

# App kustomization blocked
flux get kustomizations
flux get kustomization cnpg-operator      # is dependsOn satisfied?

# Cluster healthCheck never green
kubectl describe cluster <project>-postgres -n default
kubectl logs -l cnpg.io/cluster=<project>-postgres -n default --tail=100

# Decryption failures (missing/rotated age key)
flux logs --all-namespaces | grep -i decrypt

# Overlay reconciliation fails due to services."" (issue #136)
kubectl kustomize deploy/overlays/dev    # reproduces the failure locally
```
