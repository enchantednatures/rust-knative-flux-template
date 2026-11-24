# Service sub-template (author guide)

This directory is the **thin-service** cargo-generate template that ships inside the
platform template. It is not a template a user generates directly at the repository
root: it is selected positionally as the second argument to `cargo generate`.

> This file is author-facing documentation for the template itself. It is listed in
> `[template] ignore`, so it never appears in a generated service. Generated services
> get their own README from `README.md.liquid` (Todo 13).

## Invocation

The supported invocation (proved in `.omo/evidence/task-1-service-template.md`) is:

```bash
cargo generate --git <template-repo> service-template \
  --name <service-slug> \
  --init \
  --template-values-file <values.toml> \
  --destination <workspace>/services/<service-slug>
```

Notes:

- `<workspace>/services/<service-slug>` **must already exist** (`mkdir -p` first).
- `--init` writes directly into the destination and does not create a nested `.git`.
- The values file must be a TOML file with a `[values]` table
  (`--template-values-file` and `--values-file` are the same option).
- Every placeholder must be present in the values file for non-interactive runs;
  defaults only apply in `--silent` mode. `scripts/add-service.sh` supplies all of them.
- Never invoke `cargo generate` at the template root without the positional
  `service-template` argument: the root is itself a template and would be expanded
  instead of this sub-template.
- Do **not** add `[template] sub_templates` here. In cargo-generate 0.23.x it injects
  an interactive chooser and fails non-interactive generation with
  `Error: IO error: not a terminal`.

## Placeholder contract

The `scripts/add-service.sh` wrapper (Todo 15/17) is the intended caller and computes
these values from the generated project's local manifests:

| Group | Placeholders |
| --- | --- |
| Identity | `service_slug`, `db_name`, `project_slug`, `image_registry`, `github_org` |
| Features | `include_postgres`, `include_s3`, `kafka_publish`, `kafka_source`, `workload_deployment`, `enable_flagger`, `enable_image_updates` |
| Environments | `target_namespace_dev`, `target_namespace_staging`, `target_namespace_prod` |
| Reused infrastructure | `pg_cluster`, `pg_app_secret`, `pg_ca_secret`, `pg_pooler_host`, `redis_url`, `otel_endpoint` |
| Kafka | `kafka_bootstrap_servers`, `kafka_bootstrap_servers_staging`, `kafka_bootstrap_servers_prod`, `kafka_topic`, `kafka_consumer_group` |
| Canary gates | `canary_prometheus_url_dev`, `canary_prometheus_url_staging`, `canary_prometheus_url_prod` |

`service_slug` is the kebab-case identity used for every Kubernetes/resource/image
name; cargo-generate derives the snake-case `crate_name` from `--name` for the Rust
package. `db_name` must be a PostgreSQL-safe identifier (<= 63 bytes) and must not be
`app`, `postgres`, `template0`, or `template1`.

## Workload and feature gating

- `workload_deployment = false` (default) renders a Knative Service; `true` renders a
  plain Kubernetes Deployment. There is no enum picker, because package-name/values
  file driven generation must stay non-interactive.
- `kafka_source` is **Knative only**. The wrapper rejects it for Deployment mode; the
  conditional ignore block prunes the Knative KafkaSource files when it is false or
  when `workload_deployment = true`.
- `enable_flagger` is **Knative only**. `[conditional.'!enable_flagger || workload_deployment']`
  prunes the canary file, so a Deployment render cannot contain a Canary even if the
  value is supplied.
- `include_postgres` reuses the existing CNPG cluster: the service gets a `Database`
  CR and its own database name, but never a Cluster/Pooler/ObjectStore/backup stack.
- `include_s3` reuses the project-level `<project_slug>-app-data` Secret/ConfigMap.
  Added services never declare `objectBuckets`.
- `enable_image_updates` adds per-service Flux image resources; the shared
  `ImageUpdateAutomation` in `deploy/flux/` remains the only automation.

## Deploy file layout

```text
deploy/
├── base/
│   ├── kustomization.yaml          # HelmRelease + optional Database
│   ├── helmrelease.yaml            # workload kind, env, PG CA, Kafka, flagger
│   └── database.yaml.liquid        # include_postgres only
├── overlays/{dev,staging,prod}/
│   └── kustomization.yaml          # namespace + per-env patches
└── flux/                           # enable_image_updates only
    ├── kustomization.yaml
    ├── flux-image-repository.yaml
    └── flux-image-policy.yaml
```

The `flux/` directory is deliberately **not** referenced from `base/` or the app
overlays: the overlays' `namespace` transformer would move the Flux objects out
of `flux-system`. The platform's `deploy/flux/config/<env>/kustomization.yaml`
registers this directory when image updates are enabled. No per-service
`ImageUpdateAutomation` is rendered.

## Limitations of the pinned chart (ksvc 1.2.1)

- No HPA for Deployment workloads.
- No Flagger/Deployment canary support (canaries are Knative-only).
- KafkaSource sinks are Knative-only; Deployment services may publish to Kafka but
  cannot consume through a KafkaSource.
- Deployment exposure follows the chart's `service.type` (ClusterIP by default;
  LoadBalancer/NodePort supported by the chart). No Knative URL/ingress is synthesized.

## Hooks

This template intentionally has **no** post-generation hooks. The wrapper runs
`cargo fmt` after rendering. This avoids `--allow-commands` approval prompts and
sandbox surprises during service generation.
