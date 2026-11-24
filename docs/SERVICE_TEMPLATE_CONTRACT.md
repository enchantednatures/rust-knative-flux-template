# Per-service deploy contract (interim)

> **Status:** interim contract for the `add-service` implementation
> (`scripts/add-service.sh` / `make add-service`). The user-facing guide is
> `docs/SERVICE_TEMPLATE.md`; this file fixes the deploy-side contract that both
> the first service and every added service must follow.

The template consumes the pinned `ksvc` chart (`ksvc` **1.2.1**, OCI
`oci://ghcr.io/enchantednatures/charts`) through `deploy/chart`. Do not edit the
chart repository and do not downgrade the pin.

## 1. Layout: one service, one self-contained deploy subtree

The first service stays at the repository root and keeps today's paths:

```text
deploy/
├── base/                       # first-service HelmRelease
├── overlays/{dev,staging,prod} # first-service per-env values/patches
├── components/                 # shared cluster-wide app infra (postgres, flagger)
├── chart/                      # local wrapper chart -> ksvc 1.2.1
├── dev/app-overlay/            # Kind-only adjustments
└── flux/                       # Flux Kustomizations + image automation
```

Every added service owns its **entire** deploy subtree under
`services/<service>/deploy/`:

```text
services/<service>/deploy/
├── base/
│   ├── kustomization.yaml
│   ├── helmrelease.yaml        # metadata.name: <service>
│   └── database.yaml           # only when the shared CNPG cluster is reused
└── overlays/
    ├── dev/kustomization.yaml
    ├── staging/kustomization.yaml
    └── prod/kustomization.yaml
```

Nothing under `services/<service>/deploy/` may reference files outside its own
tree except the shared infrastructure it consumes read-only (the project-level
S3 claim Secret/ConfigMap, the CNPG cluster secret, existing Redis/OTel
endpoints). The service must **not** create another CNPG Cluster, operator,
broker, bucket claim, or `ImageUpdateAutomation`.

## 2. Registration: root overlays include the service subtree

`add-service` appends exactly one directory resource to each root environment
overlay (`deploy/overlays/{dev,staging,prod}/kustomization.yaml`):

```yaml
resources:
  - ../../base
  # Added services register their self-contained per-environment deploy
  # subtree here (written by `make add-service`):
  - ../../../services/<service>/deploy/overlays/<env>
```

Rules:

- The resource is a **directory** with its own `kustomization.yaml`. Directory
  resources across roots are allowed under kustomize's default load restrictor
  (`LoadRestrictionsRootOnly`); do **not** add `--load-restrictor=LoadRestrictionsNone`
  for this. That flag remains limited to raw-file references outside a
  kustomization root (today: the `make bootstrap` config render).
- The line is per environment; a service may be registered in one environment
  and not another only when the operator explicitly asks for that.
- Registration is idempotent: `add-service` must not append a duplicate line.
- The root overlays currently carry the line as a comment placeholder; the
  wrapper replaces it with a real resource line per service.

## 3. HelmRelease naming and values

Each service is one HelmRelease rendering the same local `deploy/chart` (ksvc
1.2.1). The release object and the rendered Knative/Deployment name are tied
together:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: <service>
  namespace: <target_namespace>
spec:
  chart:
    spec:
      chart: ./deploy/chart      # path is resolved from the Flux GitRepository root
      sourceRef:
        kind: GitRepository
        name: <project>
        namespace: flux-system
      reconcileStrategy: Revision
  values:
    global:
      fullnameOverride: "<service>"
    services:
      app:
        nameOverride: ""          # empty -> the workload is named exactly fullnameOverride
```

Contract points:

- `metadata.name` is the service slug (`<service>`), **not** `<project>-<service>`.
  The first service's release keeps its existing name, `<project>`.
- `global.fullnameOverride` equals the service slug.
- `services.app.nameOverride` is `""`; one service per release (the `app` key is
  required because the chart's Kafka sink references a named services entry).
- Per-environment overlays patch only scale/resources/environment-specific
  values on that release (`target.name: <service>`); they do not rename it.
- The first service's HelmRelease name, image, environment, and scaling must not
  change as part of this contract.

## 4. Shared infrastructure stays project-level

- PostgreSQL: one CNPG Cluster (`<project>-postgres`) owned by
  `deploy/components/postgres`. An added service that uses PostgreSQL adds a
  `Database` CR in its own subtree and points `APP__POSTGRES__DATABASE` at it;
  it never creates a second cluster or operator.
- S3: the project-level `<project>-app-data` Secret/ConfigMap (created by the
  chart's `objectBuckets` in the first-service release) is reused. Added
  services reference those names and must **not** declare `objectBuckets`.
- Redis, telemetry, Kafka/Redpanda broker wiring, and the CNPG/Flagger/ARC
  operators are read from the existing project manifests; there are no
  per-service copies.

## 5. Kind app-overlay: keep the `objectBuckets` removal name-targeted

`deploy/dev/app-overlay/kustomization.yaml` removes
`/spec/values/objectBuckets` because Kind has no bucket provisioner. The JSON6902
patch **must keep its `name` target** pointing at the first-service HelmRelease:

```yaml
patches:
  - target:
      kind: HelmRelease
      name: <project>
    patch: |-
      - op: remove
        path: /spec/values/objectBuckets
```

A generic kind-only target will match added-service HelmReleases that have no
`objectBuckets` key; kustomize then fails the entire render with
`Unable to remove nonexistent key: objectBuckets`. Added services intentionally
never declare `objectBuckets`, so the name target is part of the contract.

## 6. Image updates

`deploy/flux/image-update-automation.yaml` scans the repository root:

```yaml
  update:
    path: ./
    strategy: Setters
```

Why: the first service's setter marker lives in `deploy/base/helmrelease.yaml`,
while added services keep their markers under `services/<service>/deploy/`. A
narrower path (`./deploy`) would silently skip added services.

Marker contract (in each service HelmRelease):

```yaml
        image:
          repository: "<registry>/<org>/<service>"
          tag: "latest"  # {"$imagepolicy": "flux-system:<service>:tag"}
```

- First service marker/policy/image repository use the **platform project
  slug**, `<project>` (e.g. `ghcr.io/acme/orders`).
- Added services use `<project>-<service>` (e.g.
  `ghcr.io/acme/orders-worker`).
- The shared `ImageUpdateAutomation` is the only automation object; do not
  render a per-service one. Added services add only their `ImageRepository`
  and `ImagePolicy` objects (`<project>-<service>`), referenced from
  `deploy/flux/config/<env>/kustomization.yaml` when image updates are enabled.
- `deploy/flux/image-repository.yaml` must use the platform project slug
  (`{{ image_registry }}/{{ github_org }}/<project>`), **not** the Git
  repository name (`github_repo`). The release workflow builds the project
  image, so image automation must watch that image; using `github_repo` makes
  Flux track an image that may never exist when the repository name differs
  from the project slug.

## 7. Chart 1.2.1 constraints that shape the contract

- `workload.type: Knative` renders a Knative Service; `workload.type: Deployment`
  renders `apps/v1 Deployment` + core `v1 Service` + optional
  `PodDisruptionBudget` and emits no `autoscaling.knative.dev` annotations or
  HPA.
- `flagger.enabled` is Knative-only; the chart fails closed for a Deployment.
- `kafka.sources.*.sink` must reference a Knative service; the chart fails
  closed for a Deployment sink.
- The template does not use the 1.2.1 `pingsources` addition.

## 8. Verification for a composed project

From a generated project (or a fixture with an added service):

```bash
# Directory resources across roots work under the default restrictor.
kubectl kustomize deploy/overlays/dev
kubectl kustomize deploy/overlays/staging
kubectl kustomize deploy/overlays/prod

# First-service chart resolves the pin. Run this in the generated project:
# in the template source, deploy/chart/Chart.yaml is still Liquid and cannot
# be parsed by Helm before generation.
helm dependency build deploy/chart          # resolves ksvc 1.2.1

# Kind overlay keeps working with a service that has no objectBuckets.
kubectl kustomize deploy/dev/app-overlay
```

The first service's dev/staging/prod renders are identical on ksvc 1.2.1 and
0.8.0 apart from the whitespace the 1.2.1 loader inserts for the unused
PingSource block; no functional fields change.
