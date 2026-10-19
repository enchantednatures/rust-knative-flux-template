# FluxCD Integration Guide for PostgreSQL Feature

This guide documents how the PostgreSQL feature integrates with FluxCD for GitOps-based deployment and management.

The backup destination is a Ceph bucket that the Helm chart creates for you. Each environment declares its bucket in `objectBuckets` values, the chart renders an `ObjectBucketClaim` (OBC), and the cluster's bucket provisioner creates the bucket plus the credentials. There is no hand-made bucket and no pasted-in secret. The same mechanism feeds the app's S3 storage through a second claim (`app-data`).

## Architecture Overview

The PostgreSQL feature uses FluxCD to manage:

1. **Operator install (cluster-wide)** (`deploy/flux/cnpg-operator-kustomization.yaml`)
   - Flux Kustomization `cnpg-operator` in `flux-system`
   - Renders `deploy/infrastructure/cnpg-operator/` (CloudNativePG operator 1.28.0 + Barman Cloud Plugin v0.11.0 remote manifests) into the `cnpg-system` namespace
   - Included from `deploy/flux/config/{dev,staging,prod}/kustomization.yaml`, gated by the `feature_postgres` flag

2. **Per-environment app Kustomizations** (`deploy/flux/kustomization-{dev,staging,prod}.yaml`)
   - Each environment's existing Kustomization now carries, gated by `feature_postgres`:
     - `dependsOn: [{name: cnpg-operator}]` so CNPG CRDs exist before the component applies
     - `healthChecks` on `Cluster/{{ project_name | replace: "_", "-" }}-postgres` in the env namespace (`default` / `staging` / `production`)
     - `decryption` (SOPS: provider `sops`, secretRef `sops-age`), retained for user-managed secrets in the overlay. The backup bucket Secret is provisioner-created and is not SOPS-encrypted.

3. **PostgreSQL component** (`deploy/components/postgres/` - Kustomize Component)
   - Included from each environment overlay (`deploy/overlays/{env}/kustomization.yaml`)
   - Carries the `Cluster`, `ObjectStore`, and `ScheduledBackup` resources
   - Per-env deltas applied via JSON6902 patches in the overlays (instances, backup retention, bucket endpoint/destination)

4. **Provisioned buckets** (the app HelmRelease `objectBuckets` values)
   - Each overlay adds `objectBuckets` to the app HelmRelease (`spec.values`), one entry per consumer (`postgres-backups`, `app-data`), gated by `feature_postgres` / `feature_s3`
   - The chart renders an `ObjectBucketClaim` per entry; the cluster's bucket provisioner creates the bucket and writes a claim-named Secret (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`) and ConfigMap (`BUCKET_HOST` / `BUCKET_PORT` / `BUCKET_NAME`) into the release namespace
   - The CNPG `ObjectStore` and the app both consume those objects; nothing is created by hand

The standalone `deploy/flux/postgres-kustomization.yaml` from earlier drafts was removed: resources flow through the per-env app Kustomization so the overlay's `namespace:` transformer places everything in the right namespace and reconciliation pins to the same revision as the application.

## Prerequisites

These are cluster-level requirements. They are not installed by the template and their absence shows up as a failed app HelmRelease, not as a template error.

- **A bucket provisioner with the `ObjectBucketClaim` CRD.** The claims the chart renders need the lib-bucket-provisioner CRDs (`ObjectBucketClaim`, `ObjectBucket`), which Rook ships when its Ceph object store is enabled. The `ObjectBucketClaim` kind must exist on every cluster that runs staging or production. If it is missing, the app HelmRelease cannot apply the chart and never becomes Ready (see the failure mode in the verification runbook).
- **A bucket StorageClass with `reclaimPolicy: Retain`.** This is mandatory for backup buckets. An `ObjectBucketClaim` has no `reclaimPolicy` field, so the StorageClass governs what happens when the claim is deleted or pruned. Without `Retain`, a Flux prune (or an accidental `kubectl delete obc`) can delete the backup bucket and every backup in it. The StorageClass name is set at generate time by the `ceph_bucket_storage_class` prompt (default `ceph-bucket`).
- **An RGW endpoint reachable from the CNPG pods.** Backups run as a sidecar on the Postgres pods, so the Ceph RGW service must be resolvable and reachable from the Postgres namespace. Per-env endpoints come from the `ceph_rgw_endpoint_dev` / `ceph_rgw_endpoint_staging` / `ceph_rgw_endpoint_prod` prompts and are applied through the per-env overlays.
- **Secret handling.** The provisioner Secret is plaintext and lives only in the cluster. A Git-managed Secret must never reuse the claim name (`<project>-postgres-backups` or `<project>-app-data`); if it did, Flux would overwrite the generated credentials and break backups. SOPS decryption stays configured on the app Kustomization for any other user-managed secrets you add to the overlay.

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

**Why decryption lives here**: SOPS is retained for user-managed secrets that you add to the overlay (for example, an external storage key). The backup bucket credentials are not part of this: the provisioner creates them in-cluster and Flux never touches them. Plain files without a SOPS header pass through untouched, so decryption is safe for the whole overlay.

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
kubectl get obc -A                       # ObjectBucketClaims Bound
flux logs --all-namespaces --level=error
```

Ordering: Flux applies `cnpg-operator` first (its `wait: true` blocks on the operator Deployment). The environment's app Kustomization then applies the overlay, where the postgres component needs the CRDs the operator installs.

### 3. Environment Overlays

Each overlay:

1. Includes the postgres component (`components:` entry gated by `feature_postgres`). The overlay's `namespace:` transformer places `Cluster`/`ObjectStore`/`ScheduledBackup` into `default`/`staging`/`production`.
2. Adds the `objectBuckets` HelmRelease values for the consumers present (gated by `feature_postgres` / `feature_s3`); the chart turns each into an `ObjectBucketClaim`.
3. Applies JSON6902 patches per env (each gated by the relevant feature):
   - `Cluster /spec/instances` (`{{ postgres_instances_dev }}` / `{{ postgres_instances_staging }}` / `{{ postgres_instances_prod }}`)
   - `ObjectStore /spec/retentionPolicy` (`{{ backup_retention_dev }}d` / `{{ backup_retention_staging }}d` / `{{ backup_retention_prod }}d`)
   - `ObjectStore /spec/configuration/endpointURL` and, for staging/prod, `destinationPath` (the environment-unique bucket). You do not patch these by hand; the generated overlay carries them.
4. Applies app values through the HelmRelease JSON6902 patch in the overlay (image, scaling, gated S3 and PostgreSQL env entries).

> **Historical note**: earlier template revisions used an empty-string `services.""` HelmRelease patch key that kustomize >= 5.4 rejected (issue #136). The HelmRelease now uses a named `services.app` key, so overlays build cleanly.

## Object Storage Contract

One contract serves both consumers: the backup `ObjectStore` and the app S3 client read the same three objects that the provisioner writes. The claim name is `<release>-<key>`. The HelmRelease is named `<project>` and the value keys are `postgres-backups` and `app-data`, so the claim and its Secret/ConfigMap are `<project>-postgres-backups` and `<project>-app-data` in every environment.

For each claim the provisioner creates, in the release namespace:

- **Secret** `<claim>` with `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`
- **ConfigMap** `<claim>` with `BUCKET_HOST`, `BUCKET_PORT`, and `BUCKET_NAME`

The CNPG `ObjectStore` references the Secret by name and key (`deploy/components/postgres/postgres-backup.yaml`):

```yaml
s3Credentials:
  accessKeyId:
    name: "{{ project_name | replace: '_', '-' }}-postgres-backups"
    key: AWS_ACCESS_KEY_ID
  secretAccessKey:
    name: "{{ project_name | replace: '_', '-' }}-postgres-backups"
    key: AWS_SECRET_ACCESS_KEY
```

The app consumes the same shape from `<project>-app-data`: the Secret for `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`, and the ConfigMap for the bucket identity. Its endpoint is built from the ConfigMap:

```yaml
# BUCKET_HOST/BUCKET_PORT must be declared before APP__S3__ENDPOINT so that
# Kubernetes $(VAR) expansion can see them.
- name: APP__S3__ENDPOINT
  value: "http://$(BUCKET_HOST):$(BUCKET_PORT)"
- name: APP__S3__BUCKET
  valueFrom:
    configMapKeyRef:
      name: "{{ project_name | replace: '_', '-' }}-app-data"
      key: BUCKET_NAME
```

Because the names are delivered by the cluster, do not create them in Git. A Git-managed Secret that reused either claim name would be reconciled over the generated credentials and break backups and uploads.

## Kind vs Real Dev

The local Kind cluster has no Rook/Ceph and no bucket provisioner, so the Kind loop cannot run the claims. `deploy/dev/app-overlay` is a Kind-only Kustomize layer that neutralizes them:

- removes the `objectBuckets` HelmRelease values (no `ObjectBucketClaim` is rendered)
- points the CNPG `ObjectStore` back at the in-cluster RustFS (`http://rustfs.rustfs.svc.cluster.local:9000`)

`scripts/dev/build-and-deploy.sh`, `make local-up`, and `make dev-postgres` render that layer. The RustFS init job stands in for the provisioner: it writes the same claim-named Secret and ConfigMap keys, so the backup `ObjectStore` and the app read the same contract locally. For projects without `feature_s3`/`feature_postgres` the layer is a passthrough.

A real cluster (including a Flux-managed dev cluster) uses `deploy/overlays/dev` directly and gets the Ceph bucket from `ceph_rgw_endpoint_dev`. Only the Kind loop uses `deploy/dev/app-overlay`.

## Multi-Environment Deployment

| Environment | app Kustomization | Overlay namespace | Instances | Retention | Backup bucket | RGW endpoint |
|-------------|-------------------|-------------------|-----------|-----------|---------------|--------------|
| dev | `<project>-dev` | `default` | 1 | 7d | `<project>-postgres-backups` | `http://rook-ceph-rgw-ceph-objectstore.rook-ceph.svc:80` (`ceph_rgw_endpoint_dev`) |
| staging | `<project>-staging` | `staging` | 2 (patched) | 14d | `<project>-postgres-backups-staging` | `https://rook-ceph-rgw-ceph-objectstore.rook-ceph.svc:443` (`ceph_rgw_endpoint_staging`, placeholder) |
| production | `<project>-prod` | `production` | 3 | 30d | `<project>-postgres-backups-prod` | `https://rook-ceph-rgw-ceph-objectstore.rook-ceph.svc:443` (`ceph_rgw_endpoint_prod`, placeholder) |

The app bucket follows the same pattern: `<project>-app-data` in dev, `<project>-app-data-staging`, `<project>-app-data-prod`.

Notes:

- The dev bucket keeps the unsuffixed name; staging and prod get the environment suffix so the three can share one object store without colliding.
- The endpoint values shown for staging and prod are placeholders. Set `ceph_rgw_endpoint_staging` / `ceph_rgw_endpoint_prod` (and `ceph_rgw_endpoint_dev`) at generate time to your RGW service; the overlays patch `ObjectStore /spec/configuration/endpointURL` from them. No manual endpoint patch is needed per environment.
- Bucket names are final. The claim's `bucketName` is immutable once the claim first binds, so a late rename is rejected by the CRD. Pick names before the first deploy, and make them unique per environment.

Bootstrap the matching config (`make bootstrap dev|staging|prod`). All three environments reconcile the cluster-wide operator cleanly when `feature_postgres` is enabled at generate time.

## Escape Hatches

Use these when you are not on Ceph, or when the RGW needs TLS.

- **External S3 (AWS or any S3-compatible store).** Point the per-env overlays at your own storage instead of the chart-provisioned bucket. Two places change: replace or drop the `objectBuckets` entries in `deploy/overlays/{env}/kustomization.yaml` (drop them if the bucket and credentials already exist), and replace the `ObjectStore /spec/configuration/endpointURL` and `destinationPath` per-env patches. For plain AWS S3, remove `endpointURL` entirely and set `s3Credentials.region` instead; AWS then resolves the endpoint.
- **TLS to the RGW.** The staging and prod endpoints default to `https://...:443`, and the backup `ObjectStore` uses them as-is. The app derives its endpoint as `http://$(BUCKET_HOST):$(BUCKET_PORT)` from the claim ConfigMap; for a TLS RGW, override the app's `APP__S3__ENDPOINT` entry in the per-env HelmRelease env list (for example, `https://$(BUCKET_HOST):$(BUCKET_PORT)`).
- **Bring your own credentials.** The app and the `ObjectStore` read a Secret and a ConfigMap named after the claim. To supply your own S3 credentials, replace those `valueFrom` references (or the `s3Credentials` block) with your own Secret. Do not create a Git-managed Secret under the claim name; use a different name.

## Verification Runbook

Provisioning runs on a real cluster with a bucket provisioner. It is not exercised by the template's own CI, which has no Rook/Ceph, so verify it on the target cluster after a deploy. Provisioning also has no automated integration test in this template; this runbook is the check.

```bash
NS=default   # staging | production

# 1. The claim is Bound: the provisioner created the bucket.
kubectl get obc <project>-postgres-backups -n "$NS" -o jsonpath='{.status.phase}'
# expected: Bound

# 2. The bucket StorageClass retains buckets on delete (data-loss guardrail).
kubectl get sc <ceph_bucket_storage_class> -o jsonpath='{.reclaimPolicy}'
# expected: Retain

# 3. The provisioner delivered the objects the consumers read.
kubectl get secret <project>-postgres-backups -n "$NS"
kubectl get configmap <project>-postgres-backups -n "$NS"
kubectl get secret <project>-app-data -n "$NS"      # when feature_s3 is on
```

**Missing-CRD failure mode.** If the `ObjectBucketClaim` kind is not registered on the cluster (Rook / lib-bucket-provisioner not installed), the app HelmRelease fails while applying the chart with a "no matches for kind \"ObjectBucketClaim\"" error and never becomes Ready. The `Cluster`/`ObjectStore` resources may still exist, but no bucket or credentials are created, so backups fail against a nonexistent Secret. Install Rook (or the lib-bucket-provisioner CRDs) plus a `Retain` bucket StorageClass before deploying staging or prod.

## Troubleshooting

```bash
# Operator not ready
kubectl -n cnpg-system logs deploy/cnpg-controller-manager --tail=100

# App kustomization blocked
flux get kustomizations
flux get kustomization cnpg-operator      # is dependsOn satisfied?

# Bucket claim not Bound (missing provisioner/CRD, or RGW unreachable)
kubectl describe obc <project>-postgres-backups -n default
kubectl get sc <ceph_bucket_storage_class> -o jsonpath='{.reclaimPolicy}'

# Cluster healthCheck never green
kubectl describe cluster <project>-postgres -n default
kubectl logs -l cnpg.io/cluster=<project>-postgres -n default --tail=100

# Decryption failures (missing/rotated age key)
flux logs --all-namespaces | grep -i decrypt

# Overlays build cleanly now (issue #136 resolved via the named services.app key)
kubectl kustomize deploy/overlays/dev    # build the overlay locally
```
