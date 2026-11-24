# Adding a service to a generated project

Generated projects are Cargo workspaces: the first service is the workspace root
package and every later service lives at `services/<service-slug>/`. A later service
can be a scale-to-zero Knative Service or a plain Kubernetes Deployment.

The normal path is:

```bash
make add-service --name orders-api --workload knative
```

`make add-service` is backed by `scripts/add-service.sh`. It detects the
existing project's PostgreSQL cluster, S3 bucket claim, Redis/telemetry endpoints,
Kafka broker, namespaces, and image-update settings from local manifests, computes
the template values, runs the service template, and registers the new service in the
per-environment overlays.

## Direct cargo-generate invocation

The service template is the `service-template/` subfolder of the platform template.
cargo-generate selects it **positionally**, as the second argument:

```bash
mkdir -p services/orders-api

cargo generate --git <template-repo> service-template \
  --name orders-api \
  --init \
  --template-values-file /tmp/orders-api-values.toml \
  --destination services/orders-api
```

The same form works with a local checkout:

```bash
cargo generate --path <template-root> service-template \
  --name orders-api \
  --init \
  --template-values-file /tmp/orders-api-values.toml \
  --destination services/orders-api
```

Requirements proven during the template probes:

- The destination directory must already exist; create it with `mkdir -p` first.
- `--init` writes the service directly into the destination (no nested `.git`).
- `--template-values-file` (alias `--values-file`) must be TOML with a `[values]`
  table.
- Supply every placeholder in the values file for non-interactive runs; defaults are
  used only in `--silent` mode.
- Do not run `cargo generate` at the template root without `service-template`: the
  root is itself a template and would be expanded instead.
- The template does not use `sub_templates`; that option forces an interactive
  chooser and breaks CI generation.

The template origin used by `scripts/add-service.sh` is rendered into the generated
project at `scripts/service-template.env` (`TEMPLATE_REPO_URL` and `TEMPLATE_REF`).
Forks should override the `template_repo_url` and `template_ref` values at generation
time. `TEMPLATE_GIT_URL` / `SERVICE_TEMPLATE_REF` remain supported environment
overrides in the wrapper.

## Template values

| Group | Placeholders |
| --- | --- |
| Identity | `service_slug`, `db_name`, `project_slug`, `image_registry`, `github_org` |
| Features | `include_postgres`, `include_s3`, `kafka_publish`, `kafka_source`, `workload_deployment`, `enable_flagger`, `enable_image_updates` |
| Environments | `target_namespace_dev`, `target_namespace_staging`, `target_namespace_prod` |
| Reused infrastructure | `pg_cluster`, `pg_app_secret`, `pg_ca_secret`, `pg_pooler_host`, `redis_url`, `otel_endpoint` |
| Kafka | `kafka_bootstrap_servers`, `kafka_bootstrap_servers_staging`, `kafka_bootstrap_servers_prod`, `kafka_topic`, `kafka_consumer_group` |
| Canary gates | `canary_prometheus_url_dev`, `canary_prometheus_url_staging`, `canary_prometheus_url_prod` |

`service_slug` is kebab-case and is used for every Kubernetes, Flux, and image name.
cargo-generate derives the snake-case crate name from `--name`. `db_name` is a
separate PostgreSQL-safe identifier (<= 63 bytes) so a kebab service slug never
becomes an invalid database name.

## Workload choice and feature support

| Option | Knative Service | Kubernetes Deployment |
| --- | --- | --- |
| `workload_deployment = false` / `true` | scale-to-zero Service | Deployment + Service (+ optional PDB values) |
| `kafka_publish` | supported | supported |
| `kafka_source` | supported (KafkaSource) | not supported (forced off) |
| `enable_flagger` | supported | not supported (forced off) |
| `include_postgres` | reuses the shared CNPG cluster via a `Database` CR | same |
| `include_s3` | reuses `<project>-app-data` Secret/ConfigMap | same |
| `enable_image_updates` | per-service Flux image resources | same |

Infrastructure is always reused, never re-provisioned: a new service does not create a
CNPG Cluster, Pooler, ObjectStore, backup schedule, operator, or object-bucket claim.
It gets its own database on the existing cluster and, when enabled, its own Kafka
topic and consumer group. S3 object keys are namespaced by service name by convention.

Deployment services are exposed according to the chart's `service.type` (ClusterIP by
default; LoadBalancer/NodePort supported by the chart). They do not get a Knative URL
or ingress.

## Generated layout

```text
services/<service-slug>/
├── Cargo.toml                 # workspace member package
├── src/                       # thin service built on crates/service-core
├── config/                    # per-environment configuration
├── migrations/                # only when include_postgres
├── tests/
└── deploy/
    ├── base/                  # HelmRelease + optional Database CR
    └── overlays/{dev,staging,prod}/
```

The service keeps its complete deploy subtree next to its crate. The platform's root
overlays add the new service as a directory resource:

```yaml
resources:
  - ../../../services/<service-slug>/deploy/overlays/<env>
```

The deploy values contract (HelmRelease shape, env wiring, per-environment patches,
and Kafka DLQ post-renderer) is defined in `docs/SERVICE_TEMPLATE_CONTRACT.md`.

## Limitations

- No HPA for Deployment workloads.
- No Deployment canaries; Flagger is Knative-only.
- KafkaSource consumption is Knative-only.
- The shared `ImageUpdateAutomation` owns image updates; per-service output only adds
  `ImageRepository`/`ImagePolicy` objects.
- Migrations retry with bounded backoff at startup because the CNPG `Database` CR may
  not be reconciled when the first pod starts.
