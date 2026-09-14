# Draft: Knative Service Granularity — Multi-Binary Workspace vs Single Binary

## Original Question (user)
- Can `cargo generate` generate "snippets" — i.e., quickly scaffold a NEW binary with new Axum routes referencing a common shared crate, compiled/deployed separately, to keep Knative services small?
- OR: is it better to have one Knative service carry ALL routes and let Knative Serving/Eventing manage which endpoint traffic goes to?

## Research Findings (verified)
- **Template current state**: single package (`Cargo.toml.liquid` = `[package]`), one binary, all routes in `src/routes.rs`, feature flags (s3/postgres/kafka/flagger/gha-runner/event_source_kafka) gate deps+files at generation. Dockerfile builds one binary via cargo-chef, copies `target/release/{{ crate_name }}`.
- **Deploy side already multi-service capable**: `deploy/base/helmrelease.yaml` values contain a `services:` MAP — empty key `""` → main ksvc from fullnameOverride; chart renders one Knative Service per map key with own scaling/resources/probes/securityContext. Splitting deploy-side is nearly free.
- **cargo-generate mechanics**: it's a whole-tree project generator (Liquid templates + conditional placeholders + conditional ignore + Rhai hooks — all already used by this template). It does NOT do snippet injection into existing files; hook scripts can manipulate files post-generation. Secondary/sibling template can render a new member crate; wiring into workspace members + services map needs a hook or a script.
- **Knative Eventing routing (Oracle-verified vs spec)**: `duckv1.Destination` with `ref` (Knative Service) + relative `uri` (e.g. `/events/orders`) resolves to `<ref-url><uri>` — confirmed in Eventing control-plane spec + sinks docs. So different event types CAN be delivered to different paths of the SAME service (Trigger subscribers + Source sinks). Eventing routing is NOT a reason to split.
- **Knative autoscaling (Oracle-verified)**: minScale/maxScale/initialScale/concurrency are per-Revision annotations; changing podspec-template annotations CREATES a new revision (knative/serving#6717) — and each new revision triggers Flagger analysis. KPA scales per-Revision on aggregate concurrency; NO per-route scaling exists.
- **minScale economics**: default minScale 0 (KPA + scale-to-zero) → splitting costs ~nothing idle (queue-proxy overhead per pod); minScale≥1 on N services = N always-on pods. minScale is THE cost knob of splitting.

## Oracle Verdict
- **Staged hybrid is the right call**, with corrections:
  1. Do the workspace restructure NOW (per-binary dep isolation is impossible inside one package — all `[[bin]]` targets share one feature set/dep graph; retrofitting later = migration pain for generated users).
  2. Keep default generation = ONE service.
  3. Add opt-in "add-service" scaffolding path.
- **Split criteria (4)**: divergent scaling profile (only strict requirement), dependency weight/cold-start profile (rdkafka ~100-200ms init + binary size), independent release cadence/blast radius, divergent concurrency/timeout profile (streaming vs CRUD shouldn't share a pool).
- **Anti-criteria (do NOT split for)**: Eventing routing (ref+uri solves it), code organization (modules suffice).
- **Pitfalls — shared crate**: dep bloat (every heavy dep behind a Cargo feature with EMPTY defaults; bins opt in); don't build a mega-`Config` struct (per-service sections validated by owner bin); workspace = one lockfile = no version skew; cargo-chef `cook`/`build` scoped with `--bin <name>`; shared crate stays infrastructure-only (config/error/state/observability/middleware/health/CE-Kafka plumbing), depends on nothing internal — no domain types.
- **Pitfalls — single binary**: one scaling pool for all routes; blast radius all-or-nothing; revision churn on infra tweaks burns Flagger windows for every logical endpoint; any event type wakes the whole binary. Rust cold-start growth is modest — don't overweight.
- **Flagger × services map**: kustomize Components can't loop → template emits Canaries for generation-time-known services; the add-service scaffolder must ALSO emit the Canary (or move canary rendering into the Helm chart). Main deploy-side work item.
- **Effort estimate**: Medium (1-2 days) for workspace restructure + scaffolder; chart side mostly done.

## Proposed Architecture (hybrid)
```
generated project/
├── Cargo.toml            # [workspace]
├── crates/
│   ├── axum-cloudevents/       # vendored (already exists)
│   └── service-core/           # NEW shared crate: config, error, state, observability,
│                               #   middleware, health, CE/Kafka plumbing
│                               #   heavy deps behind empty-default features
└── services/
    └── <crate_name>/           # default first service (thin binary: main.rs + routes)
```

## Technical Decisions
- (pending user) Scaffolder mechanism: secondary cargo-generate template vs `make new-service` script
- (pending user) Whether Flagger Canary emission moves into the Helm chart or stays in scaffolder
- (pending user) Scope of first pass (workspace-only vs workspace+scaffolder)

## Open Questions
1. Do they want a plan for the hybrid restructure now, or just keep this as guidance?
2. Scaffolder preference: cargo-generate sub-template vs Makefile script?
3. Anticipated service count / load-profile divergence (does path A pay off for them)?
4. Test strategy expectations for the refactor (template e2e matrix already exists — extend to two-service case?)

## Scope Boundaries
- INCLUDE: TBD pending user answers
- EXCLUDE: TBD pending user answers
