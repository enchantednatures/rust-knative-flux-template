# Changelog

All notable changes to this template (and to the projects generated from it)
are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `kafka_managed_provider` prompt (under `kafka_managed_cluster`, default
  `redpanda`; set `strimzi` for a Strimzi operator). The generated HelmRelease
  renders the chosen provider, and `APP__KAFKA__BROKER_URL` uses the Redpanda
  service (`<project>-kafka:9093`) or the Strimzi bootstrap service
  (`<project>-kafka-kafka-bootstrap:9092`).
- `feature_bucket_notifications` prompt (under managed Kafka, default `false`):
  when `feature_s3` is also enabled, the app-data `ObjectBucketClaim` declares
  its Rook `CephObjectStore` identity and a `put` notification. The chart
  renders a `CephBucketTopic`, a `CephBucketNotification`, and the
  `<project>-app-data-put` Kafka topic; the HelmRelease adds an `s3-events`
  KafkaSource and a Trigger filtered on that source, routing the S3 payload to
  the app. `ceph_object_store_name`/`ceph_object_store_namespace` identify the
  Rook object store. Requires Rook's notification CRDs, the managed Kafka
  cluster, and the plaintext/no-auth listener; Kind fallbacks drop the path.
- `kafka_managed_cluster` prompt (under `event_source_kafka`, default `false`):
  the app chart renders a Redpanda `Redpanda` cluster + source `Topic`, a Knative
  Kafka `Broker` and `Trigger`, and a `KafkaSource` that derives its bootstrap
  from the managed cluster (`<project>-kafka.<namespace>.svc.cluster.local:9093`)
  and sinks to the Broker. The app's `APP__KAFKA__BROKER_URL` points at
  `<project>-kafka:9093`. Broker PVCs use `kafka_storage_class` (default
  `ceph-block`; empty falls back to the cluster default). Managed mode also ships
  `deploy/kyverno/policyexception.yaml` for the operator's privileged `tuning`
  init container; `deploy/dev/app-overlay` reverts to the local Kafka
  StatefulSet for `make local-up`.
- `axum-cloudevents` and `axum-cloudevents-macros` now have unit tests covering
  structured/binary extraction, header and metadata parsing, error-to-HTTP
  mapping, and the `CloudEventTagged` derive.
- Integration suites under `tests/integration/` are compiled into the
  `integration` test target, and CI runs them against live Redis, RustFS, and
  PostgreSQL containers (`--ignored --test-threads=1`).
- CI gates for `cargo fmt --check`, a release-profile build of the all-features
  project, and the standalone CloudEvents crates.
- Root governance files: `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`,
  issue templates, and a pull-request template.

### Changed

- Template version is declared in `cargo-generate.toml` (`[template] version`).
- `postgres_storage_class` now sets the CNPG `Cluster`'s `storage.storageClass`.
- `docs/TESTING.md`, `docs/FAQ.md`, and `scripts/README.md` describe the current
  Kind-based workflow instead of the removed local E2E shell suite.

### Fixed

- `LICENSE` is MIT, matching `Cargo.toml` and the README (it previously carried
  the Unlicense text).
- The Docker `HEALTHCHECK` uses `curl`, which is installed in the runtime image
  (`wget` was never present, so every container reported unhealthy).
- Flagger's documented metric-template variables survive generation (wrapped in
  Liquid raw tags), so the `target`, `namespace`, and `interval` placeholders
  reach the cluster intact.
- The generated README documents the real Kind workflow and no longer links to
  `docker-compose.yaml` or files that do not exist.
- `cargo-generate.toml` ignore entries point at real paths, and
  template-internal files (`AGENTS.md`, research notes, CI-only workflows) no
  longer leak into generated projects.
- `CloudEventTagged` accepts the documented
  `#[cloud_event_type("...")]` form, and binary mode is detected from any
  `ce-*` header, so a missing `ce-id` reports `MissingHeader` instead of a JSON
  parse error.
- GitHub Actions no longer float on `master`/`main`/`latest` refs, and mixed
  majors are aligned across workflows.

### Removed

- Stale local test tooling that referenced deleted manifests:
  `scripts/test-template-matrix.sh`, `scripts/test-template-e2e-local.sh`,
  `scripts/cleanup-e2e-local.sh`, `scripts/validate-knative-service.sh`, the
  `tests/e2e/` suite, `tests/TEST_PLAN.md`, and
  `.github/workflows/LOCAL_TESTING_QUICK_REF.md`. End-to-end coverage lives in
  CI (`template-e2e-test.yaml`).

## [1.0.0] - 2026-11-03

First tagged release. The template generates a Rust 2024 / Axum 0.8 service that
deploys to Knative Serving through FluxCD, with every optional feature behind a
`cargo-generate` prompt.

### Supported feature matrix

Generation prompts (all default to `false` unless noted):

| Prompt | What it adds |
|--------|--------------|
| `feature_s3` | S3/RustFS storage via OpenDAL, `ObjectBucketClaim`-sourced credentials |
| `feature_postgres` | CloudNativePG cluster, TLS + SCRAM, embedded sqlx migrations, item CRUD |
| `postgres_pooler` (default `true`) | PgBouncer `Pooler` in transaction mode, routed via `APP__POSTGRES__HOST` |
| `feature_kafka` | Non-blocking CloudEvents publishing with Prometheus metrics |
| `event_source_kafka` | Knative `KafkaSource` with a dead-letter-queue handler |
| `feature_cron` | Knative `PingSource` scheduled work (`dev.knative.sources.ping`) |
| `feature_flagger` | Flagger canary with Prometheus success-rate, p99, and custom gates |
| `feature_gha_runner` | ARC runner scale set with a Docker-in-Docker sidecar |
| `feature_cluster_smoke` | Post-merge workflow that verifies the deployed revision |
| `enable_image_updates` | Flux `ImageRepository`/`ImagePolicy`/`ImageUpdateAutomation` |
| `custom_domain` | `ClusterDomainClaim` + `DomainMapping` |
| `git_auth_secret` / `image_pull_secret` | SSH deploy key and private-registry pull secret |

Infrastructure and tooling:

- Knative Serving v1.20.0 (Kourier), FluxCD `HelmRelease` rendering the local
  `deploy/chart` wrapper around the `ksvc` chart 1.0.0.
- CloudNativePG 1.28.0 + Barman Cloud plugin 0.11.0 installed cluster-wide by
  Flux, with `ScheduledBackup` retention per environment (7/14/30 days).
- Local Kind lifecycle (`make local-up`, `make dev-restart`, `make dev-logs`,
  `make local-down`) with Redis, RustFS, Kafka, and the observability stack.
- `make bootstrap <env>` / `make deploy <env>` for GitOps bootstrap, and
  `make git-auth` for private repositories.

Compatibility contract:

- CI generates and validates 12 feature combinations
  (`generate-and-validate` matrix) and runs 5 live Kind + Knative deployments
  (`template-e2e-test.yaml`: `with-s3`, `with-gha-runner`, `with-flagger`,
  `with-postgres`, `with-cron`).
- Rust 1.92+ (MSRV) on the 2024 edition; toolchain pinned in
  `rust-toolchain.toml`.
- cargo-generate >= 0.23.0.

Out of scope for 1.0.0 (tracked in the backlog, not blocking the tag):

- JWT authentication (#118) and the event idempotency guard (#120).
- Kubernetes Pod Security Standards enforcement (#119); the Trivy image scan
  gate does ship in the generated `ci.yaml`/`release.yaml`.
- Optional components that are not yet implemented: schema registry (#144),
  cosign + Kyverno verification (#132), Strimzi dev operator (#131), KEDA
  lag-based autoscaling (#130), Redis caching (#126), Knative config tuning
  (#124), External Secrets Operator (#121), shared observability component
  (#122).

`feature_cron` (PR #163) is **in** 1.0.0: it ships as the `feature_cron` prompt
with a Knative `PingSource`.

### Added

- Complete Rust + Knative + FluxCD template with optional S3, Kafka (publisher
  and event source), PostgreSQL with backups, scheduled work, canary releases,
  self-hosted runners, and post-deploy smoke verification.
- OpenTelemetry tracing (B3 propagation), Prometheus metrics, health endpoints,
  rate limiting, request-ID propagation, and security headers.
- Generation matrix, full-stack validation, and live E2E CI workflows.
- Documentation suite under `docs/`, including deployment, storage, PostgreSQL,
  Kafka, Flagger, scheduled work, and runbooks.

### Security

- SOPS support for secret management (`.sops.yaml.example`).
- Non-root container, read-only-friendly manifests, and documented hardening in
  `docs/SECURITY.md`.
- CI Trivy scans and optional Kubernetes Pod Security checks in the generated
  workflows.

## Release checklist

Before tagging:

- [ ] `main` is green (`Template Generate & Validate`, `E2E Tests`,
      `Naming Convention Tests`)
- [ ] Bump `[template] version` in `cargo-generate.toml`
- [ ] Add the dated section to this file
- [ ] `cargo fmt --all -- --check` and `cargo clippy -- -D warnings` pass in the
      generated all-features project
- [ ] Tag: `git tag -a vX.Y.Z -m "Release vX.Y.Z"` and `git push origin vX.Y.Z`
- [ ] Publish the GitHub release with the supported feature matrix
