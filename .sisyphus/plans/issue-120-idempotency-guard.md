# Issue #120: Event Idempotency Guard (specs/001-idempotency-guard)

## TL;DR

> **Quick Summary**: Implement the event idempotency guard per `specs/001-idempotency-guard/` and GitHub issue #120: a framework-agnostic core module (`src/idempotency/`) with a Redis-backed `IdempotencyStore`, RAII `ProcessingGuard`, and a thin axum middleware adapter layered **only** on the CloudEvents ingest route (`POST /`). New `feature_idempotency` cargo-generate flag gates everything. TDD throughout.
> 
> **Deliverables**:
> - `src/idempotency/` core module: key validation, `IdempotencyStore` trait, guard RAII, Redis store (SET NX EX + owner-token Lua release + completed marker)
> - `IdempotencyError` with contract-exact HTTP responses (400 / 409 / 503+Retry-After)
> - Middleware adapter wired to `POST /` only; config section `APP__IDEMPOTENCY__*`; metrics + tracing
> - Test suite: unit (in-memory mock), real-Redis integration (`#[ignore]`), 16-task concurrency exact-1, proptest key fuzzing
> - Template gating: `feature_idempotency` flag, conditional ignores, inline liquid gates, CI matrix + e2e scenario, AGENTS.md docs
> 
> **Estimated Effort**: Large
> **Parallel Execution**: YES - 7 waves
> **Critical Path**: T0 (spec reconcile) → T1 (core) → T2/T3 (redis + wiring) → T4 (middleware) → T5/T6 (metrics + tests) → T7 (gating) → T8 (docs) → F1-F4

---

## Context

### Original Request
GitHub issue #120: implement the idempotency guard from `specs/001-idempotency-guard/spec.md` — prevents duplicate event processing, complements the existing KafkaSource + DLQ setup. Full spec artifacts exist (spec, plan, research, data-model, contracts) and were reviewed and reconciled with user decisions during planning.

### Interview Summary
**Key Discussions** (all confirmed by user):
- **Architecture**: user proposed "shared axum middleware"; agreed middleware is the right *integration point* but the logic lives in a framework-agnostic core module (`src/idempotency/`), with a ~60-line adapter layered only on `POST /`. In this template the "Kafka consumer path" IS the HTTP path (Knative KafkaSource delivers binary-mode CloudEvents to `POST /`); there is no direct rdkafka consumer loop.
- **Backend**: Redis only this round (`AppState.redis` already exists); trait designed so PostgreSQL slots in later (deferred to the Postgres runtime layer issue).
- **Missing key**: reject 400 (fail-closed). No random-UUID fallback (silently disables dedup).
- **Redis unavailable**: fail-closed 503 + Retry-After (research.md "fail fast, no retries").
- **Tests**: TDD (RED-GREEN-REFACTOR per task).
- **Guard mechanism (locked after macro evaluation)**: middleware-only this round. A `#[idempotency(key, ttl)]` proc-macro was evaluated and deferred: in axum, per-route scoping IS per-handler scoping (one method+path → one handler), and the core guard is directly callable for non-HTTP functions, so the macro's only unique value is declarative ergonomics at future scale. The core (`IdempotencyGuard`/store trait) is deliberately macro-agnostic — if guarded endpoints multiply later, add the macro as a follow-up without discarding anything.

**Defaults applied from interview (disclosed)**: key extraction order = `Idempotency-Key` header → `ce-id` header → 400; `feature_idempotency` flag default **false** (consistent with all other flags).

### Research Findings
- **Redis design (spec research.md)**: `SET key value NX EX` atomic acquire; passive expiration + 10s safety margin; TTL default 300s, min 60, max 3600; "TTL ≥ 2× P99 processing time" documentation.
- **Failure policy**: no retries in the guard; 409 duplicate `{error, idempotency_key, status}`, 503 storage-unavailable + `Retry-After: 60`.
- **Metrics (spec research.md)**: `idempotency_acquire_total{backend,result}`, `idempotency_duplicates_total{backend,status}`, `idempotency_errors_total{backend,error_type}`, `idempotency_completions_total{backend}`, latency histograms; low-cardinality labels only.
- **Contract (specs/001-.../contracts/idempotency-api.yaml)**: `Idempotency-Key` header, max 255 chars, pattern `^[a-zA-Z0-9_-]+$`.

**Hard API correction (validated against redis-rs 0.24 source)**: `.nx()`/`.ex()` shorthand **does not exist**. Acquire MUST use:
```rust
redis::AsyncCommands::set_options(
    &mut conn, key, token,
    redis::SetOptions::default()
        .conditional_set(redis::ExistenceCheck::NX)
        .with_expiration(redis::SetExpiry::EX(secs)),
).await
```
`MultiplexedConnection` has **no per-op timeout** in 0.24 — wrap every op in `tokio::time::timeout`.

### Metis Review
**Identified Gaps (addressed)**:
- **Invalidated assumptions corrected**: `tests/integration/` is dead code (never compiled — no top-level `mod integration;`); real precedent is top-level `tests/storage_test.rs` with `#[ignore]`. CI never runs `cargo test` (compile-only at `template-generate-and-validate.yaml:246`); live coverage = e2e curl. `src/*.rs` files are plain `.rs` with inline liquid tags (no `.liquid` suffix needed for new source files).
- **Spec artifacts conflict with locked decisions**: `plan.md` still contains PG/sqlx scope, "Rust 1.92", handler-modification step, readiness-check claim, stale metric name. `data-model.md` documents single-key Redis storage and a success-only Drop. These are reconciled in **Task 0** so corrected docs become the executor's source of truth.
- **Race conditions encoded into design** (see Design Rules below): failed-acquire must re-check completed; owner-token + Lua compare-and-delete release prevents a stale guard from deleting another worker's lock.
- **Decisions D1–D6 applied as defaults** (see Defaults Applied in summary).

### Design Rules (BINDING for all tasks)
1. **Two-key Redis layout** (corrects data-model.md): lock key `idempotency:lock:{key}` (value = random owner token, TTL = `ttl_seconds + 10`) and completed marker `idempotency:done:{key}` (TTL = `ttl_seconds + 10`, never deleted early).
2. **Acquire flow**: (a) GET completed marker → 409 `status:"completed"`; (b) `SET NX EX` lock with token → acquired on success; (c) on NX failure → **re-check completed marker** (race: completion may land between (a) and (b)) → 409 `"processing"` or `"completed"`.
3. **Release semantics**: guard outcome — 2xx → `SET done` + Lua compare-and-delete lock; non-2xx → Lua compare-and-delete lock only; **unset/panic → release** (never mark completed).
4. **Lua compare-and-delete**: `if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end` — a stale guard must never delete another worker's lock.
5. **Key resolution in middleware**: `Idempotency-Key` header first, then `ce-id` header, else 400. Key validated per D1 (charset + length ≤ 255, trim empty → missing).
6. **Outcome determined at response-headers time** (axum `from_fn` semantics); documented limitation for streaming bodies (non-issue for JSON handlers).
7. **Both keys TTL = `ttl_seconds + 10`** (single config knob preserved; spec's dedup-window semantics kept over the generic 24h-marker guidance).

---

## Work Objectives

### Core Objective
Prevent duplicate processing of events with the same idempotency key within the configured TTL window, behind a `feature_idempotency` cargo-generate flag, with Redis-backed TTL-locked processing, race-safe concurrency, and contract-exact error responses.

### Concrete Deliverables
- `src/idempotency/mod.rs`, `key.rs`, `error.rs`, `store.rs`, `guard.rs`, `redis_store.rs`
- `src/middleware.rs`: `idempotency_middleware` adapter
- `src/routes.rs`: route-scoped layer on `POST /` (inline liquid gate)
- `src/config.rs` + `config/*.toml`: `IdempotencyConfig` section (gated)
- `src/state.rs` + `src/main.rs`: `Option<Arc<IdempotencyGuard>>` in AppState (minimal-diff wiring)
- `src/observability.rs`: gated metric `describe_*` calls
- `tests/idempotency_test.rs` + `tests/idempotency_concurrent_test.rs` + proptest additions
- `cargo-generate.toml`: `feature_idempotency` + conditional ignores
- `.github/workflows/template-generate-and-validate.yaml` + `template-e2e-test.yaml`: idempotency scenarios
- `AGENTS.md` + `README.md.liquid`: idempotency section

### Definition of Done
- [ ] `cargo fmt --all -- --check` passes
- [ ] `cargo clippy --all-targets --all-features -- -D warnings` passes
- [ ] `cargo test` passes (unit + property + concurrency); `cargo test -- --ignored` passes with local Redis running
- [ ] `cargo generate` with flag ON produces a compiling project; with flag OFF produces zero `idempotency` occurrences in generated source
- [ ] FR-001..FR-010 from spec.md satisfied (FR-004 PostgreSQL deferred by design)

### Must Have
- Two-key Redis design with owner-token Lua release (Design Rules 1-4)
- Key extraction: `Idempotency-Key` → `ce-id` → 400
- Fail-closed errors: 400 missing/invalid key, 409 duplicate, 503 + Retry-After on storage failure/timeout
- RAII guard: 2xx → completed; non-2xx/panic → release
- Route-scoped middleware on `POST /` only; health/metrics untouched
- Metrics with low-cardinality labels; idempotency key NEVER a metric label
- `#[instrument]` on all public async fns; structured logging on state transitions
- TDD: every implementation task preceded by failing tests

### Must NOT Have (Guardrails)
- ❌ NO PostgreSQL backend code, sqlx dependency, PG tests, or migration SQL (deferred to Postgres runtime layer issue)
- ❌ NO response replay on duplicate (409-only semantics)
- ❌ NO retries/backoff/circuit breaker inside the guard (fail fast is locked)
- ❌ NO key extraction from payload / composite source+id keying
- ❌ NO `instance_id`/`acquired_at` fields in 409 responses (contract trimmed)
- ❌ NO readiness/liveness endpoint changes (readiness does NOT check idempotency backend)
- ❌ NO Prometheus alert rules, dashboards, k6, or Flagger metric-template wiring
- ❌ NO fake-clock/TTL-simulation infra; NO admin/cleanup endpoints; NO active key sweeping
- ❌ NO changes to `tests/integration/` (dead directory — do not build on or refactor it)
- ❌ NO new Cargo dependencies (redis/tokio/axum/metrics/thiserror all present; use `std::time`, NOT chrono)
- ❌ NO global middleware layers; NO AppState constructor variant explosion (unconditional `Option` field, minimal diff)
- ❌ NO `.unwrap()`/`.expect()` in production code; NO idempotency key as metric label
- ❌ NO generic names (`data`, `result`, `item`, `temp`); NO commented-out code; NO AI slop comments

---

## Verification Strategy (MANDATORY)

> **ZERO HUMAN INTERVENTION** - ALL verification is agent-executed. No exceptions.

### Test Decision
- **Infrastructure exists**: YES (cargo test, axum-test + tower::ServiceExt oneshot, proptest, metrics-exporter-prometheus for assertions)
- **Automated tests**: TDD (RED → GREEN → REFACTOR per task)
- **Framework**: cargo test (unit + property), real-Redis integration tests top-level with `#[ignore = "requires Redis running (docker run -p 6379:6379 redis:7)"]` (pattern: `tests/storage_test.rs`)
- **CRITICAL**: CI never executes `cargo test` (compile-only). Real-Redis tests run locally/manually; live-path coverage in CI comes from the e2e curl scenario (Task 7).

### QA Policy
Every task includes agent-executed QA scenarios below. Evidence saved to `.sisyphus/evidence/task-{N}-{slug}.{ext}`.
- **Library/Module**: Bash (cargo test / cargo clippy) with exact test names and assertions
- **Template**: Bash (cargo generate both flag states + grep assertions + cargo check in generated project)
- **E2E**: workflow YAML follows existing curl patterns (`template-e2e-test.yaml:849-921`)

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 0 (Start immediately):
└── T0: Spec artifact reconciliation [writing]

Wave 1 (After T0 — foundation):
└── T1: Core module (key, trait, guard RAII) TDD [deep]

Wave 2 (After T1):
├── T2: Redis store (NX/EX, owner token, Lua release) TDD [deep]
└── T3: Config + AppState wiring + error responses TDD [unspecified-high]

Wave 3 (After T2+T3 — integration point):
└── T4: Middleware adapter on POST / TDD [deep]

Wave 4 (After T4):
├── T5: Metrics + tracing instrumentation TDD [unspecified-high]
└── T6: Integration + concurrency + property tests [unspecified-high]

Wave 5 (After T5+T6):
└── T7: Template gating (flag, ignores, CI matrices, smoke) [deep]

Wave 6 (After T7):
└── T8: AGENTS.md + README docs [writing]

Wave FINAL (After ALL tasks — 4 parallel reviews, then user okay):
├── F1: Plan compliance audit (oracle)
├── F2: Code quality review (unspecified-high)
├── F3: Real manual QA (unspecified-high)
└── F4: Scope fidelity check (deep)
-> Present results -> Get explicit user okay

Critical Path: T0 → T1 → T2 → T4 → T6 → T7 → T8 → F1-F4 → user okay
```

### Dependency Matrix
- **T0**: blocked by none → blocks T1
- **T1**: blocked by T0 → blocks T2, T3
- **T2**: blocked by T1 → blocks T4
- **T3**: blocked by T1 → blocks T4
- **T4**: blocked by T2, T3 → blocks T5, T6
- **T5**: blocked by T4 → blocks T7
- **T6**: blocked by T4 → blocks T7
- **T7**: blocked by T5, T6 → blocks T8
- **T8**: blocked by T7 → blocks FINAL

### Agent Dispatch Summary
- **W0**: 1 — T0 → `writing`
- **W1**: 1 — T1 → `deep`
- **W2**: 2 — T2 → `deep`, T3 → `unspecified-high`
- **W3**: 1 — T4 → `deep`
- **W4**: 2 — T5 → `unspecified-high`, T6 → `unspecified-high`
- **W5**: 1 — T7 → `deep`
- **W6**: 1 — T8 → `writing`
- **FINAL**: 4 — F1 → `oracle`, F2 → `unspecified-high`, F3 → `unspecified-high`, F4 → `deep`

---

## TODOs

- [ ] T0. Spec artifact reconciliation (docs only)

  **What to do**:
  - `specs/001-idempotency-guard/data-model.md`: replace single-key Redis storage with the **two-key design** (Design Rules 1–4 in this plan: lock key + completed marker, owner token, Lua compare-and-delete release); correct key-extraction order (`Idempotency-Key` header → `ce-id` → reject, ce-id NOT preferred); document the failure-path Drop (non-2xx/panic → release, never mark completed); mark all PostgreSQL sections "DEFERRED — see Postgres runtime layer issue".
  - `specs/001-idempotency-guard/plan.md`: remove PostgreSQL/sqlx from Technical Context + Project Structure + task expectations; correct "Rust 1.92 (edition 2024)" → match repo toolchain; replace stale metric name `idempotency_checks_total` with the research.md names (`idempotency_acquire_total`, etc.); replace the "handlers/events.rs MODIFIED: Add idempotency guard usage example" line with "middleware adapter on POST / (handlers untouched)"; delete the "readiness check will verify idempotency backend connectivity" claim (explicitly excluded).
  - `specs/001-idempotency-guard/spec.md`: append an **Amendments** section noting: FR-004/US-3 (PostgreSQL backend) deferred to the Postgres runtime layer issue; two-key storage design adopted; fail-closed behaviors locked (missing key → 400, storage error → 503).
  - `specs/001-idempotency-guard/contracts/idempotency-api.yaml`: remove optional `acquired_at`/`instance_id` fields from the 409 response schema/examples (required fields only: `error`, `idempotency_key`, `status`).

  **Must NOT do**:
  - Rewrite spec history: preserve original decision records, append amendments only.
  - Touch any `src/` or workflow files.

  **Recommended Agent Profile**:
  - **Category**: `writing`
    - Reason: pure markdown/docs editing, no code.
  - **Skills**: [] — no domain skill overlaps; spec knowledge is provided inline in this task.
  - **Skills Evaluated but Omitted**:
    - `specify`: spec already exists; this is reconciliation, not creation.

  **Parallelization**:
  - **Can Run In Parallel**: NO (Wave 0 gate — corrected docs are the source of truth for T1–T8)
  - **Parallel Group**: Wave 0
  - **Blocks**: T1
  - **Blocked By**: None

  **References** (executor has NO interview context — these are their only guide):
  - `specs/001-idempotency-guard/data-model.md` — the file to correct: single-key design + success-only Drop + ce-id-preferred are all superseded by this plan's Design Rules section
  - `specs/001-idempotency-guard/plan.md:14-50` — Technical Context block containing "Rust 1.92", sqlx 0.8, and stale metric names to remove; `plan.md:108-138` — Project Structure with postgres.rs/tests to de-scope; `plan.md:58` — readiness-check claim to delete
  - `specs/001-idempotency-guard/spec.md:126-140` — Assumptions/Out of Scope section, where the Amendments section must be appended after (do not alter FR numbering)
  - `specs/001-idempotency-guard/research.md:542-551` — Decision Summary table: the metric names, fail-fast policy, and TTL guidance that plan.md must match (research.md is NOT edited — it is correct)
  - `specs/001-idempotency-guard/contracts/idempotency-api.yaml` — 409 response schema with optional fields to trim
  - **WHY**: T1–T8 executors will read these docs; stale claims (PG backend, success-only Drop, ce-id-preferred) would directly produce wrong code.

  **Acceptance Criteria**:

  > **AGENT-EXECUTABLE VERIFICATION ONLY**

  - [ ] `grep -i "sqlx" specs/001-idempotency-guard/plan.md` → 0 matches
  - [ ] `grep -i "postgres" specs/001-idempotency-guard/plan.md` → only DEFERRED mentions
  - [ ] `grep "idempotency_checks_total" specs/001-idempotency-guard/plan.md` → 0 matches
  - [ ] `grep -c "two-key\|lock key\|completed marker" specs/001-idempotency-guard/data-model.md` → ≥ 3 matches
  - [ ] `grep -A2 "Amendments" specs/001-idempotency-guard/spec.md` → section exists listing FR-004 deferral + fail-closed decisions
  - [ ] `grep -c "acquired_at\|instance_id" specs/001-idempotency-guard/contracts/idempotency-api.yaml` → 0 matches
  - [ ] `grep "ce-id" specs/001-idempotency-guard/data-model.md` → only in the corrected extraction-order context (header first, ce-id fallback)

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Docs consistency sweep (happy path)
    Tool: Bash
    Preconditions: none
    Steps:
      1. Run all grep assertions from Acceptance Criteria; capture output
      2. Read each edited file top-to-bottom to confirm no broken markdown/links
    Expected Result: every grep matches its expected count; no dangling references to removed content
    Failure Indicators: any stale "sqlx", "postgres.rs", "idempotency_checks_total", or optional-409-field mention outside DEFERRED context
    Evidence: .sisyphus/evidence/task-0-spec-reconciliation.txt

  Scenario: Negative — reconciliation must not rewrite history
    Tool: Bash
    Steps:
      1. `git diff --stat specs/001-idempotency-guard/`
      2. Confirm edits are additive/corrective, not wholesale rewrites (no file loses its original decision records)
    Expected Result: diffs are localized; FR-001..010 untouched
    Failure Indicators: spec.md FR section modified or deleted
    Evidence: .sisyphus/evidence/task-0-no-rewrite.txt
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-0-spec-reconciliation.txt` (grep outputs)
  - [ ] `.sisyphus/evidence/task-0-no-rewrite.txt` (diff stat)

  **Commit**: YES — `docs(specs): reconcile 001 idempotency artifacts with locked decisions`

- [ ] T1. Core module: key validation, store trait, guard RAII (TDD)

  **What to do**:
  - Create `src/idempotency/mod.rs` (public re-exports: `IdempotencyGuard`, `ProcessingGuard`, `IdempotencyStore`, `IdempotencyKey`, `IdempotencyError`, `AcquireResult`), `key.rs`, `error.rs`, `store.rs`, `guard.rs`.
  - `key.rs`: `IdempotencyKey` newtype — parse from optional header values: resolve `Idempotency-Key` header first, then `ce-id`; trim; empty after trim = missing; validate ≤255 chars and pattern `^[a-zA-Z0-9_-]+$` (D1: enforce contract charset); `as_str()` accessor.
  - `error.rs`: `IdempotencyError` enum — `MissingKey`, `InvalidKey { reason: String }`, `Duplicate { key: String, status: DuplicateStatus }` (processing|completed), `StorageUnavailable(String)`, `Timeout(String)`, `CompletionFailed(String)`. NO axum imports in this file (the `IntoResponse` impl lands in T4's middleware adapter).
  - `store.rs`: `IdempotencyStore` trait — `async fn check_completed(&self, key: &str) -> Result<bool, IdempotencyError>`, `async fn acquire(&self, key: &str, ttl: Duration) -> Result<Option<String>, IdempotencyError>` (returns owner token if acquired, None if lock held), `async fn release(&self, key: &str, token: &str) -> Result<(), IdempotencyError>` (compare-and-delete), `async fn mark_completed(&self, key: &str, ttl: Duration) -> Result<(), IdempotencyError>`. Trait object safe (`Arc<dyn IdempotencyStore>`); no axum/redis types in signatures.
  - `guard.rs`: `ProcessingGuard` RAII — holds `Arc<dyn IdempotencyStore>`, key, token, outcome enum (`Unset | Succeeded | Failed`), constructed via `IdempotencyGuard::acquire(store, key, ttl)` which implements the full Design-Rule-2 flow: check_completed → acquire → on NX failure re-check completed → map to `Ok(ProcessingGuard)` or `Err(IdempotencyError::Duplicate)`; `set_succeeded()`/`set_failed()`; `Drop` implements Design-Rule-3 (Succeeded → mark_completed + release; anything else → release only; Drop must log a warning if outcome is Unset). `#[instrument(skip(...))]` on all public async fns per AGENTS.md.
  - TDD: write failing unit tests FIRST in `#[cfg(test)]` inline modules using a minimal inline mock store (NOT a public `InMemoryStore` in src — clippy dead-code in later flag-off builds; the shared in-memory store for integration tests lives in `tests/common/mod.rs` in T6). Tests: acquire→Succeeded→completed marked + lock released; acquire→Failed→lock released, completed NOT marked; Unset drop→release; duplicate while processing → 409 processing; duplicate after completion → 409 completed; failed-acquire re-check (mock where completed lands between check and NX).

  **Must NOT do**:
  - No axum/redis imports anywhere in `src/idempotency/{key,error,store,guard}.rs`.
  - No chrono (use `std::time::{Duration, Instant}`).
  - No public test-only store in src.
  - No metrics in this task (T5).

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: correctness-critical concurrency semantics (RAII, race re-check, outcome transitions) demand thorough reasoning.
  - **Skills**: [] — standard Rust; repo patterns provided in references.
  - **Skills Evaluated but Omitted**:
    - `test-driven-development`: TDD loop is already specified step-by-step here; follow the plan.

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 1 (solo — foundation)
  - **Blocks**: T2, T3
  - **Blocked By**: T0

  **References**:
  - `specs/001-idempotency-guard/research.md:160-248` — TTL strategy (2× P99 guidance, safety margin) and concurrency decision matrix the guard must implement
  - `specs/001-idempotency-guard/data-model.md` — AFTER T0 corrections: state transitions and record fields
  - `src/error.rs:1-60` — thiserror enum style to mirror (`#[derive(Error, Debug, Clone)]`, `#[error("...")]` messages); NOTE: IdempotencyError is a SEPARATE type, not an AppError variant
  - `src/middleware.rs:8-11` — import style; `AGENTS.md` §Instrumentation — `#[instrument(skip(state, ...))]` and `fields(...)` conventions, err(Debug) on fallible fns
  - `src/handlers/events.rs:1-31` — the handler the middleware will wrap (read-only context for T4)
  - **WHY**: guard.rs encodes the entire correctness story (races, outcome rules); error.rs is the contract type every later task maps from; the trait is the PG-future seam — keep it clean.

  **Acceptance Criteria** (TDD — tests first):

  > **AGENT-EXECUTABLE VERIFICATION ONLY**

  - [ ] `cargo test idempotency` → all unit tests pass: `acquire_succeeds_and_marks_completed_on_success`, `release_on_failure_allows_retry`, `unset_outcome_releases_never_completes`, `duplicate_processing_returns_409_processing`, `duplicate_completed_returns_409_completed`, `failed_acquire_rechecks_completed`
  - [ ] `cargo test key` → `valid_key_accepted`, `empty_key_missing`, `key_over_255_rejected`, `key_invalid_charset_rejected`, `header_preferred_over_ce_id`, `ce_id_fallback`, `whitespace_trimmed`
  - [ ] `cargo clippy --all-targets --all-features -- -D warnings` → clean
  - [ ] `grep -rn "axum\|redis::" src/idempotency/key.rs src/idempotency/store.rs src/idempotency/guard.rs src/idempotency/error.rs` → 0 matches

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Guard lifecycle happy path
    Tool: Bash (cargo test)
    Preconditions: T1 code on branch, inline mock store
    Steps:
      1. cargo test idempotency::guard -- --nocapture
      2. Assert acquire returns ProcessingGuard; set_succeeded; drop
      3. Assert mock store: completed marker set, lock released, exactly in that logical order
    Expected Result: all guard tests green; no Unset-warning logged on Succeeded path
    Failure Indicators: completed marked on Failed path; lock held after drop; panic in Drop
    Evidence: .sisyphus/evidence/task-1-guard-lifecycle.txt

  Scenario: Negative — outcome defaults to release (never completed) on unset
    Tool: Bash (cargo test)
    Steps:
      1. cargo test unset_outcome_releases_never_completes -- --nocapture
      2. Assert warning log emitted for Unset outcome
    Expected Result: lock released, completed marker ABSENT, warning logged
    Failure Indicators: completed marker present after unset drop (would lose the event on retry)
    Evidence: .sisyphus/evidence/task-1-unset-release.txt

  Scenario: Negative — failed-acquire re-check race
    Tool: Bash (cargo test)
    Steps:
      1. cargo test failed_acquire_rechecks_completed -- --nocapture
      2. Mock store where mark_completed lands between check_completed and acquire; assert result is Duplicate{status: completed}, NOT Duplicate{status: processing}
    Expected Result: re-check produces correct status
    Failure Indicators: stale "processing" status reported
    Evidence: .sisyphus/evidence/task-1-race-recheck.txt
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-1-guard-lifecycle.txt`
  - [ ] `.sisyphus/evidence/task-1-unset-release.txt`
  - [ ] `.sisyphus/evidence/task-1-race-recheck.txt`
  - [ ] `.sisyphus/evidence/task-1-clippy.txt`

  **Commit**: YES — `feat(idempotency): core module — key validation, store trait, guard RAII`

- [ ] T2. Redis store: NX/EX acquire, owner-token release, completed marker (TDD)

  **What to do**:
  - Create `src/idempotency/redis_store.rs`: `RedisStore` implementing `IdempotencyStore`, constructed from `redis::aio::MultiplexedConnection` (clone of `AppState.redis` — reuse; NO new connection config).
  - **API DISCIPLINE (hard requirement — redis-rs 0.24 has NO `.nx()`/`.ex()` shorthand)**: acquire MUST use
    `AsyncCommands::set_options(&mut conn, lock_key, token, SetOptions::default().conditional_set(ExistenceCheck::NX).with_expiration(SetExpiry::EX(secs)))`.
  - Keys: `idempotency:lock:{key}` (value = random owner token via `uuid::Uuid::new_v4()`, EX = ttl_secs + 10) and `idempotency:done:{key}` (value = "1", EX = ttl_secs + 10). Constants for prefixes.
  - `check_completed` → EXISTS on done key. `mark_completed` → SET with EX. `release` → **Lua compare-and-delete** (Design Rule 4): `EVAL "if redis.call('get',KEYS[1]) == ARGV[1] then return redis.call('del',KEYS[1]) else return 0 end" 1 lock_key token` — a stale guard must never delete another worker's lock.
  - Every Redis op wrapped in `tokio::time::timeout(Duration::from_millis(timeout_ms), …)` — `MultiplexedConnection` has NO per-op timeout in 0.24; map timeout → `IdempotencyError::Timeout`; map `RedisError` → `IdempotencyError::StorageUnavailable`.
  - `#[instrument(skip(self), fields(idempotency_key = %key, backend = "redis", ttl_seconds = ttl.as_secs()), err(Debug))]` on all methods.
  - TDD: real-Redis tests FIRST in top-level `tests/idempotency_test.rs` (shared file with T6 — create with redis-store tests now), marked `#[ignore = "requires Redis running (docker run -p 6379:6379 redis:7)"]`, connecting via `APP__REDIS__URL` (default `redis://localhost:6379`), mirroring `tests/storage_test.rs`'s ignore+connect pattern. Tests: `acquire_succeeds_once`, `second_acquire_none`, `completed_check_distinguishes_states`, `owner_release_deletes_own_lock`, `foreign_token_release_noop` (A acquires; release with wrong token → lock intact), `completed_survives_release`, `short_ttl_expiry_allows_reacquire` (ttl 1s → sleep ~1.3s → reacquire Some).

  **Must NOT do**:
  - No `.nx()`/`.ex()` method calls (does not exist in redis 0.24 — will not compile).
  - No ConnectionManager / new client construction (reuse the shared MultiplexedConnection).
  - No Lua beyond the single compare-and-delete script.
  - No key-expiry simulation infrastructure.

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: atomic Redis semantics + Lua + timeout wrapping; correctness-critical.
  - **Skills**: [] — API specifics embedded verbatim in this task.
  - **Skills Evaluated but Omitted**:
    - `librarian`: redis API already validated against source (redis-rs 0.24 tag `redis-0.24.0`).

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with T3 — disjoint files)
  - **Blocks**: T4
  - **Blocked By**: T1

  **References**:
  - `specs/001-idempotency-guard/research.md:9-31,109-162` — SET NX EX semantics, passive-expiration margin (+10s), TTL bounds
  - `src/state.rs:10-21` — `redis: MultiplexedConnection` field the store clones from
  - `Cargo.toml.liquid:63` — `redis = { version = "0.24", features = ["tokio-comp", "connection-manager"] }` (features already present; no dep changes)
  - `tests/storage_test.rs` — THE pattern for top-level integration tests: `#[ignore = "requires …"]` marker + env-based connection + local Docker service
  - `tests/common/mod.rs` — existing shared helpers; add the shared `InMemoryStore` for integration tests here in T6, NOT in this task
  - `src/handlers/kafka.rs:63-130` — redis error-context logging style (`error_type`, `error_context` fields)
  - **WHY**: the SetOptions API correction is the #1 hallucination risk in this task; the ignore-pattern test file is the #2 (tests/integration/ is dead code — do not use it).

  **Acceptance Criteria** (TDD — tests first):

  > **AGENT-EXECUTABLE VERIFICATION ONLY**

  - [ ] `grep -n "SetOptions\|conditional_set\|with_expiration" src/idempotency/redis_store.rs` → ≥ 1 match; `grep -n "\.nx()\|\.ex()" src/idempotency/` → 0 matches
  - [ ] `grep -n "tokio::time::timeout" src/idempotency/redis_store.rs` → ≥ 4 matches (every op wrapped)
  - [ ] `grep -n "EVAL\|eval\|redis.call" src/idempotency/redis_store.rs` → compare-and-delete script present
  - [ ] `cargo test idempotency_redis` (unit, compile-level) → compiles
  - [ ] `cargo test --test idempotency_test -- --ignored` with local Redis (`docker run -d -p 6379:6379 redis:7`) → all 7 integration tests pass
  - [ ] `cargo clippy --all-targets --all-features -- -D warnings` → clean

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Atomic acquire + owner-token release (happy path)
    Tool: Bash
    Preconditions: local Redis running (docker run -d -p 6379:6379 redis:7; skip if already listening)
    Steps:
      1. cargo test --test idempotency_test -- --ignored --nocapture
      2. Observe acquire_succeeds_once → Some(token); second_acquire_none → None
      3. Observe owner_release_deletes_own_lock passes AND foreign_token_release_noop passes (lock value unchanged after foreign release)
    Expected Result: 7/7 integration tests pass
    Failure Indicators: foreign release deleted the lock; reacquire fails after TTL sleep; timeout not mapped to Timeout error
    Evidence: .sisyphus/evidence/task-2-redis-integration.txt

  Scenario: Negative — TTL expiry permits retry (crash simulation)
    Tool: Bash
    Steps:
      1. cargo test --test idempotency_test short_ttl_expiry_allows_reacquire -- --ignored --nocapture
      2. Acquire with ttl=1s, drop guard with outcome Failed (release), sleep >1.3s, reacquire
    Expected Result: reacquire succeeds (lock expired via TTL)
    Failure Indicators: reacquire returns None (lock leaked)
    Evidence: .sisyphus/evidence/task-2-ttl-expiry.txt

  Scenario: Negative — Redis unreachable maps to storage error
    Tool: Bash
    Steps:
      1. Ensure no Redis on localhost:6379 (docker stop / different port)
      2. Run the #[ignore] tests against a dead port via APP__REDIS__URL=redis://localhost:6399
      3. Assert tests fail with StorageUnavailable/Timeout mapping (not panic)
    Expected Result: error mapping verified, no panic, no .unwrap
    Failure Indicators: panic/unwrap in error path
    Evidence: .sisyphus/evidence/task-2-redis-down.txt
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-2-redis-integration.txt`
  - [ ] `.sisyphus/evidence/task-2-ttl-expiry.txt`
  - [ ] `.sisyphus/evidence/task-2-redis-down.txt`

  **Commit**: YES — `feat(idempotency): redis store — NX/EX acquire, owner-token release, completed marker`

- [ ] T3. Config + AppState wiring + error responses (TDD)

  **What to do**:
  - `src/config.rs`: add `IdempotencyConfig` struct — `backend: String` (default `"redis"`; validation: only `"redis"` accepted this round, any other value → config error), `ttl_seconds: u64` (default 300; validation: 60..=3600 per research.md bounds), `timeout_ms: u64` (default **1000** per D4; validation: 1..=60000). Add gated field to `Config`: `{% if feature_idempotency %}pub idempotency: IdempotencyConfig,{% endif %}` + gated `Default` impl entry + figment env overrides work automatically via existing `APP__` prefix handling.
  - `config/default.toml` (+ environment tomls if the pattern requires): gated `{% if feature_idempotency %}[idempotency]{% endif %}` section with defaults. (Check `config/` dir contents for the exact file set and nesting convention first.)
  - `src/state.rs`: add unconditional field `pub idempotency: Option<Arc<crate::idempotency::IdempotencyGuard>>` — mirroring the `kafka_publisher: Option<Arc<KafkaPublisher>>` pattern — and extend all **4** `AppState::new` variants with one `idempotency` param each (minimal diff; no variant explosion).
  - `src/main.rs`: one gated construction block `{% if feature_idempotency %}` building the guard from `config.idempotency` + `redis_conn.clone()` + `Arc<dyn IdempotencyStore>`-backed `RedisStore` `{% endif %}`, and pass it at the 4 `AppState::new` call sites (pass `None` when feature off via the unconditional param).
  - `src/idempotency/error.rs`: add `impl IntoResponse for IdempotencyError` mapping (contract-exact):
    - `MissingKey` → 400, body `{"error": "Missing idempotency key", "details": ["Provide Idempotency-Key header or ce-id (CloudEvents)"]}`
    - `InvalidKey { reason }` → 400, body `{"error": "Invalid idempotency key", "details": [reason]}`
    - `Duplicate { key, status }` → 409, body `{"error": "Duplicate event", "idempotency_key": key, "status": status}` (REQUIRED — exactly these three fields)
    - `StorageUnavailable(_)` / `Timeout(_)` → 503, body `{"error": "Idempotency storage unavailable", "error_type": "unavailable"|"timeout"}` + header `Retry-After: 60`
    - Log via `tracing::error!/warn!` with `error_type` context per existing AppError pattern.
  - TDD: failing tests first — config validation unit tests (TTL 59 → error, 3601 → error, 300 ok; timeout bounds; backend `"postgres"` → error with clear message); `IntoResponse` tests via `tower::ServiceExt::oneshot` on a tiny router returning each error (exact JSON bodies + Retry-After header asserted).

  **Must NOT do**:
  - No new `AppState::new` variant combinations (unconditional Option param only).
  - No AppError changes (separate type, separate IntoResponse).
  - No readiness/liveness changes.

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: multi-file wiring with liquid gates; mechanical but touches the constructor matrix — needs care, not deep research.
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `data-model-design`: schema already fixed by spec data-model.md.

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with T2 — disjoint files; both touch nothing the other owns)
  - **Blocks**: T4
  - **Blocked By**: T1

  **References**:
  - `src/config.rs:55-130` — Config struct + gated fields (`{% if feature_kafka %}pub kafka: Option<KafkaConfig>{% endif %}`) + Default impl + validation style (`Config::validate` returning descriptive errors)
  - `src/config.rs:130-180` — figment loading order; `APP__` env prefix (e.g. `APP__IDEMPOTENCY__TTL_SECONDS=120`)
  - `src/state.rs:14-30` — `kafka_publisher: Option<Arc<KafkaPublisher>>` field pattern to mirror exactly
  - `src/state.rs:50-99` — the 4 `AppState::new` variants (s3 × kafka matrix) needing the one new param each
  - `src/main.rs:31-113` — construction flow: metrics → redis → (gated blocks) → 4 `AppState::new` call sites; add ONE gated guard-construction block + 4 param updates
  - `src/error.rs:94-150` — IntoResponse pattern: `(StatusCode, error_message, details)` + `tracing` with `error_type`; body JSON shape for reference (IdempotencyError uses its OWN shapes per contract)
  - `specs/001-idempotency-guard/contracts/idempotency-api.yaml` — exact 409/503 response schemas + `Retry-After` header
  - **WHY**: the 4-variant constructor matrix is liquid-time (one variant exists post-generation); missing one call site = broken template. Config validation bounds come verbatim from research.md; timeout default 1000ms per D4.

  **Acceptance Criteria** (TDD — tests first):

  > **AGENT-EXECUTABLE VERIFICATION ONLY**

  - [ ] `cargo test config` → `ttl_below_min_rejected` (59), `ttl_above_max_rejected` (3601), `ttl_default_ok` (300), `timeout_bounds_rejected`, `unsupported_backend_rejected`
  - [ ] `cargo test idempotency_error` → oneshot assertions: 409 body EXACTLY `{"error":"Duplicate event","idempotency_key":"k","status":"processing"}`; 503 body has `error_type` and response has `Retry-After: 60` header; 400 bodies for MissingKey/InvalidKey
  - [ ] `cargo check` + `cargo clippy --all-targets --all-features -- -D warnings` → clean
  - [ ] `grep -c "AppState::new" src/main.rs` → 4 call sites each receiving the new param

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Error contract exactness
    Tool: Bash (cargo test)
    Preconditions: T1+T3 code
    Steps:
      1. cargo test idempotency_error -- --nocapture
      2. Assert 409 JSON has exactly 3 fields (error, idempotency_key, status) — no extras
      3. Assert 503 sets Retry-After: 60
    Expected Result: byte-exact JSON bodies per contract
    Failure Indicators: AppError-shaped {error, details, request_id} leaking into idempotency responses
    Evidence: .sisyphus/evidence/task-3-error-contract.txt

  Scenario: Negative — invalid config fails fast at startup
    Tool: Bash
    Steps:
      1. APP__IDEMPOTENCY__TTL_SECONDS=59 cargo run (or cargo test with that env)
      2. Assert startup/config-load error names the violating field and bounds
    Expected Result: fail-fast with actionable message; service does not start
    Failure Indicators: silent default fallback or panic without context
    Evidence: .sisyphus/evidence/task-3-config-validation.txt
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-3-error-contract.txt`
  - [ ] `.sisyphus/evidence/task-3-config-validation.txt`

  **Commit**: YES — `feat(idempotency): config, AppState wiring, error responses`

- [ ] T4. Middleware adapter on POST / (TDD)

  **What to do**:
  - `src/middleware.rs`: add `pub async fn idempotency_middleware(State(state): State<AppState>, req: Request<Body>, next: Next) -> Response` (axum `from_fn_with_state` signature style; follow the existing `request_id_middleware` file conventions):
    1. Resolve key: `Idempotency-Key` header → `ce-id` header → `IdempotencyError::MissingKey` (400). Validate via `IdempotencyKey`.
    2. `state.idempotency` is `None` (feature off / not constructed) → pass through untouched (defensive no-op).
    3. `guard.acquire(store, key, ttl).await`: `Err(Duplicate)` → return its 409 response; `Err(StorageUnavailable|Timeout)` → 503; `Ok(guard)` → proceed.
    4. `let response = next.run(req).await`; inspect `response.status()`: 2xx → `guard.set_succeeded()`, else → `guard.set_failed()`; return response. (Outcome decided at headers time — documented streaming limitation.)
    5. `impl IntoResponse for IdempotencyError` may live here if the executor prefers adapter-local mapping — EITHER way it must be in exactly one place (decided: keep in `src/idempotency/error.rs` from T3; do not duplicate).
  - `src/routes.rs`: wire on `POST /` ONLY via MethodRouter `route_layer`, inline-liquid gated:
    ```liquid
    .route("/", post(events::handle_event)
    {%- if feature_idempotency %}
        .route_layer(axum::middleware::from_fn_with_state(state.clone(), crate::middleware::idempotency_middleware))
    {%- endif %})
    ```
    (Note: `state` is moved into `create_router` — clone before the router builder consumes it; `from_fn_with_state` runs BEFORE global TraceLayer spans, so instrument the middleware itself for tracing.)
  - TDD: failing oneshot tests first in `src/middleware.rs` `#[cfg(test)]` (inline mock store via a test AppState) — the full matrix from Acceptance Criteria below. Additional test: router built WITHOUT the layer (simulating flag off) never enforces keys on `POST /`.

  **Must NOT do**:
  - NO global `.layer()` on the outer Router (health/metrics must never require keys).
  - NO changes to `handlers/events.rs` (handlers untouched by design).
  - NO body buffering/parsing (header-only key resolution).

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: axum layering order + from_fn_with_state + liquid-gated MethodRouter wiring; subtle integration.
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `api-design`: contract fixed by spec; this is wiring, not design.

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 3 (solo — integrates T2+T3)
  - **Blocks**: T5, T6
  - **Blocked By**: T2, T3

  **References**:
  - `src/middleware.rs:32-83` — `request_id_middleware` (from_fn signature, `next.run(req).await`, response header mutation) to mirror structurally
  - `src/middleware.rs:238-276` — oneshot test pattern (`tower::ServiceExt::oneshot`, `Request::builder()`, header assertions)
  - `src/routes.rs:82` — the exact `POST /` route line being gated; `src/routes.rs:96-104` — global layers that must NOT receive the idempotency layer
  - `src/routes.rs:107-113` — `api_v1_routes()` showing existing inline-liquid gating style in this file
  - `src/state.rs:14-30` — `Option<Arc<...>>` field semantics the middleware must defensively handle (None → pass-through)
  - `src/handlers/events.rs:26-31` — the wrapped handler (returns 200 `Json<Pong>` → 2xx → completed)
  - `specs/001-idempotency-guard/contracts/idempotency-api.yaml` — header parameter spec + response contracts
  - **WHY**: axum 0.8 MethodRouter supports `.route_layer` per-route — this is the mechanism that keeps health endpoints key-free; getting layer order wrong would gate `/health/*` and break Knative probes (deployment-killing failure mode).

  **Acceptance Criteria** (TDD — tests first):

  > **AGENT-EXECUTABLE VERIFICATION ONLY**

  - [ ] `cargo test middleware::idempotency` → full matrix passes: `missing_key_returns_400`, `invalid_charset_returns_400`, `header_preferred_over_ce_id`, `ce_id_fallback_uses_event_id`, `first_request_200_marks_completed`, `duplicate_while_processing_409`, `duplicate_after_completion_409_completed_status`, `handler_500_releases_lock` (second request then acquires), `store_error_returns_503_with_retry_after`, `health_endpoint_needs_no_key` (GET /health/live via a router WITH the layer → 200)
  - [ ] `cargo test routes` → `post_route_gated_by_flag` compiles for both liquid branches (validated fully in T7; here: `cargo check` clean)
  - [ ] `grep -n "route_layer" src/routes.rs` → present inside `{% if feature_idempotency %}` gate; `grep -n "\.layer(axum::middleware::from_fn(idempotency" src/routes.rs` → 0 (never global)
  - [ ] `cargo clippy --all-targets --all-features -- -D warnings` → clean

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Duplicate matrix end-to-end through middleware
    Tool: Bash (cargo test)
    Preconditions: T1-T4 complete; inline mock store
    Steps:
      1. cargo test middleware::idempotency -- --nocapture
      2. Send request 1 (Idempotency-Key: "evt-1") → 200; request 2 (same key) → 409 with status field; request 3 (ce-id header only) → dedup independent of header source
    Expected Result: full matrix 10/10 green
    Failure Indicators: 409 body missing status field; ce-id events bypass dedup; health endpoints 400ing
    Evidence: .sisyphus/evidence/task-4-middleware-matrix.txt

  Scenario: Negative — handler failure releases lock for retry
    Tool: Bash (cargo test)
    Steps:
      1. cargo test handler_500_releases_lock -- --nocapture
      2. Request 1 → handler returns 500 (test router); request 2 same key → acquires (not 409)
    Expected Result: released lock permits retry; completed marker ABSENT
    Failure Indicators: 500 marked completed (event lost on retry) or lock stuck (retry 409s forever)
    Evidence: .sisyphus/evidence/task-4-failure-release.txt
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-4-middleware-matrix.txt`
  - [ ] `.sisyphus/evidence/task-4-failure-release.txt`

  **Commit**: YES — `feat(idempotency): event ingest middleware on POST /`

- [ ] T5. Metrics + tracing instrumentation (TDD)

  **What to do**:
  - `src/observability.rs`: add gated `describe_*` pre-registrations following the existing pattern: `describe_counter!("idempotency_acquire_total", "...")`, `describe_counter!("idempotency_duplicates_total", "...")`, `describe_counter!("idempotency_errors_total", "...")`, `describe_counter!("idempotency_completions_total", "...")`, `describe_histogram!("idempotency_acquire_latency_seconds", buckets [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0])`, `describe_histogram!("idempotency_processing_duration_seconds", ...)` — all inside `{% if feature_idempotency %}` gates. Names verbatim from spec research.md (NOT the stale `idempotency_checks_total`).
  - Instrument call sites (gated inline liquid where files are shared): `acquire()` increments `idempotency_acquire_total{backend="redis", result=acquired|duplicate|error}` + latency histogram; duplicate path increments `idempotency_duplicates_total{status=processing|completed}`; error path increments `idempotency_errors_total{error_type=timeout|unavailable|completion_failed}`; successful completion increments `idempotency_completions_total{backend="redis"}` + processing-duration histogram (acquire→completion time measured in guard Drop).
  - **LABEL HYGIENE (hard rule)**: idempotency key value must NEVER appear as a metric label. Only `backend`, `result`, `status`, `error_type` labels — cardinality-safe.
  - Verify tracing: `#[instrument]` spans on acquire/release/mark_completed produce `idempotency_key`, `backend`, `ttl_seconds` fields; middleware span wraps handler (visible in Jaeger under the POST / trace).
  - TDD: failing test first using `metrics_exporter_prometheus::PrometheusBuilder` with a test-local recorder — build a minimal router with the middleware + mock store, fire requests, scrape the handle, assert counter values and labels exactly.

  **Must NOT do**:
  - No gauge metrics (`idempotency_processing_locks` is PG-only per research.md).
  - No Prometheus alert rules / dashboards / k6 / Flagger templates.
  - No key-valued labels.

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: mechanical instrumentation across shared files with liquid gates + a recorder-based test.
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `performance-review`: NFR-008 is declared prod-monitored, not an optimization task.

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 4 (with T6 — T5 touches src instrumentation; T6 touches tests/ only)
  - **Blocks**: T7
  - **Blocked By**: T4

  **References**:
  - `specs/001-idempotency-guard/research.md:373-538` — the metrics/tracing/logging spec: names, labels, histogram buckets, span fields, log messages (follow verbatim)
  - `src/observability.rs:31-62` — existing `describe_counter!`/`describe_histogram!` pre-registration pattern + liquid gating style
  - `src/handlers/kafka.rs:210-225` — runtime `counter!`/histogram usage pattern at call sites with label syntax
  - `src/middleware.rs:44-56` — Instant-based latency measurement pattern
  - **WHY**: metric renames after export = broken dashboards; the names/labels must land exactly once, exactly right.

  **Acceptance Criteria** (TDD — tests first):

  > **AGENT-EXECUTABLE VERIFICATION ONLY**

  - [ ] `cargo test idempotency_metrics` → recorder assertions: acquire → `idempotency_acquire_total{backend="redis",result="acquired"}` == 1; duplicate → `result="duplicate"` + `idempotency_duplicates_total{status="processing"}`; storage error → `idempotency_errors_total{error_type="unavailable"}`; success → `idempotency_completions_total{backend="redis"}` ≥ 1
  - [ ] `grep -rn 'label.*key\|"key" =>' src/idempotency/ src/middleware.rs` → 0 matches (no key-valued labels)
  - [ ] `cargo clippy --all-targets --all-features -- -D warnings` + `cargo fmt --all -- --check` → clean

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Metric contract via test recorder
    Tool: Bash (cargo test)
    Steps:
      1. cargo test idempotency_metrics -- --nocapture
      2. Fire 3 requests: success, duplicate(processing), store-error; scrape test recorder
      3. Assert each counter/histogram exactly (names + labels + values)
    Expected Result: all assertions pass; buckets include 0.05 (NFR-008 observability)
    Failure Indicators: wrong label keys, missing counter increments, key value in labels
    Evidence: .sisyphus/evidence/task-5-metrics.txt

  Scenario: Negative — label hygiene
    Tool: Bash
    Steps:
      1. grep -rn 'key' src/idempotency/redis_store.rs src/idempotency/guard.rs | grep -i 'label\|counter!\|histogram!'
      2. Manually inspect each hit: key must never be a label value
    Expected Result: zero key-labeled metrics
    Failure Indicators: any metrics! call embedding the idempotency key (cardinality explosion in prod)
    Evidence: .sisyphus/evidence/task-5-label-hygiene.txt
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-5-metrics.txt`
  - [ ] `.sisyphus/evidence/task-5-label-hygiene.txt`

  **Commit**: YES — `feat(idempotency): metrics and tracing instrumentation`

- [ ] T6. Integration + concurrency + property tests

  **What to do**:
  - `tests/idempotency_test.rs` (created in T2 with redis-store tests): add middleware-level integration tests — real Redis + oneshot router with `RedisStore`: full duplicate flow (200 → 409 processing → 409 completed after completion), TTL-expiry retry, fail-closed 503 when Redis down. All `#[ignore = "requires Redis running …"]`.
  - Add shared `InMemoryStore` (a simple `Mutex<HashMap>` implementing `IdempotencyStore` with exact-1 acquire semantics) to `tests/common/mod.rs` — used by concurrency tests; NOT in src (clippy dead-code in flag-off builds).
  - Create `tests/idempotency_concurrent_test.rs`: 16 tokio tasks racing `acquire()` on the SAME key against the shared InMemoryStore → **exactly 1** returns Acquired, 15 return Duplicate (deterministic; runs in CI without Redis). Mirror a variant against real Redis under `#[ignore]`.
  - Extend `tests/property_tests.rs` (proptest precedent): key validation property — generated strings: len 1..=255 conforming charset → `Ok`; len 0/256 or charset violations → `Err`; also TTL bounds property (59/3601 rejected, 60/300/3600 accepted).
  - Run instruction in file docs: `cargo test -- --ignored` requires `docker run -d -p 6379:6379 redis:7`.

  **Must NOT do**:
  - Nothing in `tests/integration/` (dead directory).
  - No testcontainers dependency; no fake-clock infra.
  - No test that requires CI to have Redis running (CI never runs cargo test).

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: substantial test authoring across three files; follows established patterns closely.
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `test`: test strategy already fully specified in this plan.

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 4 (with T5 — disjoint: tests/ vs src instrumentation)
  - **Blocks**: T7
  - **Blocked By**: T4

  **References**:
  - `tests/storage_test.rs` — `#[ignore = "…"]` + env-based connection pattern (THE precedent; tests/integration/ is dead code — never add there)
  - `tests/property_tests.rs` — proptest strategy style + `proptest!` macro usage
  - `tests/events_test.rs` + `src/middleware.rs:238-276` — oneshot router test patterns for middleware-level tests
  - `tests/common/mod.rs` — shared helpers location for `InMemoryStore`
  - `specs/001-idempotency-guard/spec.md:17-24` — acceptance scenarios 1–4 these tests verify (duplicate reject, completed recognize, TTL retry)
  - **WHY**: concurrency exact-1 is THE correctness proof (SC-001); property tests lock the fail-closed key contract; integration tests prove the Redis path works with real expiry semantics.

  **Acceptance Criteria**:

  > **AGENT-EXECUTABLE VERIFICATION ONLY**

  - [ ] `cargo test idempotency_concurrent` → passes: 16 racers, exactly 1 Acquired (in-memory, deterministic — runs everywhere)
  - [ ] `cargo test property idempotency` → key/TTL property tests pass (fuzzed)
  - [ ] `cargo test -- --ignored` with local Redis → middleware-level integration tests pass (duplicate flow, TTL retry, 503 fail-closed)
  - [ ] `grep -rn "mod integration" tests/*.rs` → 0 matches (dead dir untouched)
  - [ ] `cargo clippy --all-targets --all-features -- -D warnings` → clean

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Race safety proven (happy path)
    Tool: Bash (cargo test)
    Steps:
      1. cargo test idempotency_concurrent -- --nocapture
      2. Assert output: Acquired count == 1, Duplicate count == 15
    Expected Result: deterministic exact-1 under 16-way race
    Failure Indicators: >1 Acquired (SC-001 violated) or 0 Acquired (deadlock)
    Evidence: .sisyphus/evidence/task-6-concurrency.txt

  Scenario: Negative — fail-closed when Redis down (integration)
    Tool: Bash
    Steps:
      1. Point APP__REDIS__URL at a dead port; cargo test --test idempotency_test -- --ignored middleware_down_tests
      2. Assert POST returns 503 with Retry-After (not 200 without dedup)
    Expected Result: fail-closed behavior verified against real connection failure
    Failure Indicators: fail-open (200) or panic
    Evidence: .sisyphus/evidence/task-6-fail-closed.txt
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-6-concurrency.txt`
  - [ ] `.sisyphus/evidence/task-6-fail-closed.txt`

  **Commit**: YES — `test(idempotency): redis integration, concurrency, property tests`

- [ ] T7. Template gating: feature_idempotency flag (flag, ignores, CI, smoke)

  **What to do**:
  - `cargo-generate.toml`: add `feature_idempotency = { prompt = "Enable event idempotency guard (Redis-backed dedup)?", type = "bool", default = false }` in the feature-toggles block; add `[conditional.'!feature_idempotency']` ignore list (negated syntax — ignores when OFF): the new test files (`tests/idempotency_test.rs`, `tests/idempotency_concurrent_test.rs`) + docs file if one is created. NOTE: `src/idempotency/` module + inline-gated shared files (routes/main/state/config/observability) are handled by inline liquid gates, NOT ignores (files must stay for the flag-ON render); verify this by checking how `feature_kafka` handles `src/handlers/kafka.rs` (ignore-listed because the whole file is kafka-only) vs `src/state.rs` (inline-gated because shared).
  - `src/lib.rs`: add gated module declaration `{% if feature_idempotency %}pub mod idempotency;{% endif %}` (check current lib.rs structure first).
  - Shared-file inline gates audit — verify each has its gate after T1–T6 (T7 is the completeness pass): `src/routes.rs` (route_layer), `src/main.rs` (guard construction), `src/config.rs` (field + Default), `src/state.rs` (Option field + params), `src/observability.rs` (describe_*), `Cargo.toml.liquid` (no dep changes needed — redis already unconditional). Use `grep -n "feature_idempotency" src/` to enumerate; every idempotency artifact must be behind a gate.
  - `.github/workflows/template-generate-and-validate.yaml`: add idempotency to the matrix — extend the existing `all-features`-style entry with `feature_idempotency=true` AND add one dedicated `with-idempotency` scenario entry (same structure as existing scenario blocks; cargo generate → cargo fmt/clippy/test compile). Follow the exact YAML shape of neighboring entries.
  - `.github/workflows/template-e2e-test.yaml`: add a `with-idempotency` scenario (deploy=true, `--define feature_idempotency=true`, Redis already provisioned by the workflow) + duplicate-event curl assertions following the existing curl pattern: POST `/` with `Idempotency-Key: idem-e2e-1` + a valid CloudEvent payload → expect 200; identical second POST → expect **409** with body containing `"status"` field. Also assert `GET /health/live` still 200 (no key required).
  - Smoke test BOTH flag states (agent-executed):
    - ON: `cargo generate --path . --name idem-smoke-on --define feature_idempotency=true --destination /tmp/opencode/idem-on` → `cd /tmp/opencode/idem-smoke-on/idem-smoke-on && cargo check && cargo clippy --all-targets -- -D warnings` → clean; `grep -ri idempotency src/ Cargo.toml | wc -l` → > 0
    - OFF: `cargo generate --path . --name idem-smoke-off --define feature_idempotency=false --destination /tmp/opencode/idem-off` → cargo check clean; `grep -ri idempotency src/ Cargo.toml tests/ | wc -l` → **0** (zero-overhead guarantee)

  **Must NOT do**:
  - No ignore-list entry for shared files (would break flag-ON renders).
  - No workflow refactor beyond additive entries.
  - No e2e additions beyond the one scenario + curl assertions.

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: template mechanics are subtle (ignore vs inline gate, conditional syntax, matrix YAML); errors here break every generated project.
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `ci-cd`: workflow edits follow existing file patterns directly.

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 5 (solo — gates the entire feature)
  - **Blocks**: T8, FINAL
  - **Blocked By**: T5, T6

  **References**:
  - `cargo-generate.toml:44-52` — feature-toggle block to extend; `cargo-generate.toml:148` — `[conditional.'feature_kafka']` placeholders pattern; `cargo-generate.toml:153` — the negated-ignore pattern `[conditional.'!feature_kafka']` with file-list semantics to copy
  - `src/handlers/kafka.rs` vs `src/state.rs` — the two gating strategies: whole-file ignore (`kafka.rs` is in `!feature_kafka` ignore list) vs inline liquid (`state.rs` shared) — idempotency src module is whole-module (ignore `src/idempotency/` when off? NO — inline `pub mod` gate in lib.rs is cleaner and keeps the ignore list minimal; EITHER approach is acceptable but pick ONE: recommend ignore-list `src/idempotency` + inline gates for shared files, mirroring kafka exactly)
  - `.github/workflows/template-generate-and-validate.yaml` — matrix entries + scenario block structure (`--define` flag passing, tempdir generate, fmt/clippy/test steps)
  - `.github/workflows/template-e2e-test.yaml:591-601,665-673,849-921` — Redis provisioning (bitnami), redis-url secret, curl assertion patterns to mirror for the duplicate-event test
  - `.github/workflows/dev-setup-validation.yaml` — also passes `--define` flags; check whether its matrix needs the flag (add `feature_idempotency=false` default or an entry — decide by reading its scenario list)
  - `AGENTS.md` §Naming Conventions — no naming impact, but generated-project greps must respect crate_name vs project_name
  - **WHY**: a missing ignore entry ships dead idempotency code to every flag-OFF project (fails "zero-overhead"); a wrong ignore entry breaks flag-ON projects; the e2e curl is the ONLY place CI executes the duplicate flow.

  **Acceptance Criteria**:

  > **AGENT-EXECUTABLE VERIFICATION ONLY**

  - [ ] `grep -n "feature_idempotency" cargo-generate.toml` → placeholder + conditional sections present
  - [ ] `grep -rn "feature_idempotency" src/` → every idempotency artifact gated (routes, main, state, config, observability, lib)
  - [ ] Flag-ON smoke: generated project passes `cargo check` + `cargo clippy --all-targets -- -D warnings`; idempotency grep count > 0
  - [ ] Flag-OFF smoke: generated project passes `cargo check`; **`grep -ri idempotency src/ Cargo.toml tests/ | wc -l` → 0**
  - [ ] `yaml lint`-level check (or python yaml.safe_load) on both edited workflows → valid YAML
  - [ ] `.github/workflows/template-generate-and-validate.yaml` matrix contains an idempotency scenario; `template-e2e-test.yaml` contains the with-idempotency scenario + duplicate curl (first 200, second 409 with `status`)

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Template smoke — both flag states
    Tool: Bash
    Preconditions: T1-T6 complete, working tree clean-ish
    Steps:
      1. cargo generate --path . --name idem-smoke-on --define feature_idempotency=true --destination /tmp/opencode/idem-on
      2. cd /tmp/opencode/idem-on/idem-smoke-on && cargo check && cargo clippy --all-targets -- -D warnings
      3. grep -ri idempotency src/ | wc -l  → > 0
      4. cargo generate --path . --name idem-smoke-off --define feature_idempotency=false --destination /tmp/opencode/idem-off
      5. cd /tmp/opencode/idem-off/idem-smoke-off && cargo check
      6. grep -ri idempotency src/ Cargo.toml tests/ | wc -l  → 0
    Expected Result: ON compiles with feature present; OFF compiles with ZERO idempotency artifacts
    Failure Indicators: either cargo check fails; OFF grep > 0 (gate leak); ON grep == 0 (over-gating)
    Evidence: .sisyphus/evidence/task-7-smoke-on.txt, .sisyphus/evidence/task-7-smoke-off.txt

  Scenario: Negative — flag-OFF has zero overhead
    Tool: Bash
    Steps:
      1. In /tmp/opencode/idem-off generated project: grep -ri "idempotency\|IdempotencyKey\|IdempotencyGuard" src/ Cargo.toml
      2. Confirm /health routes and main.rs contain no idempotency references
    Expected Result: binary identical to pre-feature template (modulo unrelated changes)
    Failure Indicators: any leaked import, config section, or metric describe
    Evidence: .sisyphus/evidence/task-7-zero-overhead.txt
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-7-smoke-on.txt`
  - [ ] `.sisyphus/evidence/task-7-smoke-off.txt`
  - [ ] `.sisyphus/evidence/task-7-zero-overhead.txt`

  **Commit**: YES — `feat(template): gate idempotency behind feature_idempotency flag`

- [ ] T8. AGENTS.md + README documentation

  **What to do**:
  - `AGENTS.md`: add "## Event Idempotency Guard" section (mirroring the "Kafka Event Publishing Patterns" section style): what it does, the two-key Redis design summary, key extraction order, fail-closed behavior table (400/409/503), completion rule (2xx/else/panic), config reference (`APP__IDEMPOTENCY__BACKEND|TTL_SECONDS|TIMEOUT_MS` with defaults + bounds + "TTL ≥ 2× P99 processing time" guidance), metrics list, testing instructions (`cargo test -- --ignored` + docker command), and the middleware integration pattern (route-scoped, handlers untouched).
  - `README.md.liquid`: add a short idempotency feature bullet/section gated `{% if feature_idempotency %}` where features are listed (follow existing feature-section gating pattern) + config env-var table row.
  - Update `specs/001-idempotency-guard/quickstart.md` if it exists post-T0 (plan.md promised it) with 5-step integration guide per plan.md's Integration Guide contents — only if quickstart.md exists; otherwise note in the AGENTS.md section (single source of truth: AGENTS.md).
  - Keep documentation tight: no tutorials, no marketing copy — operator/agent reference facts only.

  **Must NOT do**:
  - No documentation of PostgreSQL backend (deferred — say so explicitly if mentioned at all).
  - No emoji (repo AGENTS.md style is emoji-light; README uses some — follow the target file's existing style, do not introduce new emoji elsewhere).
  - No stale path/variable references (this repo JUST cleaned those in issues #115/#116 — do not reintroduce `knative-service.yaml`-style ghosts or undefined template variables).

  **Recommended Agent Profile**:
  - **Category**: `writing`
    - Reason: pure documentation.
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `document`: repo has its own doc conventions; follow AGENTS.md/README patterns directly.

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 6 (solo — documents the finalized behavior)
  - **Blocks**: FINAL
  - **Blocked By**: T7

  **References**:
  - `AGENTS.md` — "Kafka Event Publishing Patterns" section structure (configuration table, error-handling patterns, metrics queries) to mirror; also the recent #115/#116 cleanup: every referenced path/variable must exist or be a real defined placeholder
  - `README.md.liquid` — feature-section gating pattern (`{% if feature_kafka %}` blocks) and config/env-var table style
  - `specs/001-idempotency-guard/research.md:533-538` — metric names for the documentation table
  - `src/config.rs` (post-T3) — exact env var names and validation bounds to document
  - **WHY**: AGENTS.md drives AI agents working in generated projects — stale or invented config names here recreate the issue-#115 class of bugs.

  **Acceptance Criteria**:

  > **AGENT-EXECUTABLE VERIFICATION ONLY**

  - [ ] `grep -n "APP__IDEMPOTENCY__" AGENTS.md` → all 3 vars documented with correct defaults (redis / 300 / 1000) and bounds (60..=3600 / 1..=60000)
  - [ ] `grep -n "feature_idempotency" README.md.liquid` → gated section present
  - [ ] Path/variable audit: every backticked path in the new AGENTS.md section exists on disk; every `{{ var }}` is a defined cargo-generate placeholder
  - [ ] `cargo fmt --all -- --check` + clippy still clean (docs commit shouldn't touch code — verify nothing drifted)

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Docs accuracy audit
    Tool: Bash
    Steps:
      1. Extract every backticked path from the new AGENTS.md idempotency section; test -e each
      2. Extract every {{ var }}; cross-check against cargo-generate.toml [placeholders]
      3. Compare documented defaults against src/config.rs values
    Expected Result: 0 stale paths, 0 undefined variables, defaults match code
    Failure Indicators: any invented env var, wrong default, or nonexistent path
    Evidence: .sisyphus/evidence/task-8-docs-audit.txt

  Scenario: Negative — no reintroduced staleness
    Tool: Bash
    Steps:
      1. grep -rn "postgres_cluster_name\|kafka_brokers\|enable_kafka\|knative-service.yaml" AGENTS.md README.md.liquid
    Expected Result: 0 matches
    Failure Indicators: any hit (regression of issues #115/#116)
    Evidence: .sisyphus/evidence/task-8-staleness.txt
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-8-docs-audit.txt`
  - [ ] `.sisyphus/evidence/task-8-staleness.txt`

  **Commit**: YES — `docs(idempotency): AGENTS.md section and configuration reference`

---

## Final Verification Wave (MANDATORY — after ALL implementation tasks)

> 4 review agents run in PARALLEL. ALL must APPROVE. Present consolidated results to user and get explicit "okay" before completing.
>
> **Do NOT auto-proceed after verification. Wait for user's explicit approval before marking work complete.**

- [ ] F1. **Plan Compliance Audit** — `oracle`
  Read the plan end-to-end. For each "Must Have": verify implementation exists (read file, run command). For each "Must NOT Have": search codebase for forbidden patterns (sqlx, postgres.rs, global idempotency layer, readiness changes, key-as-metric-label) — reject with file:line if found. Check evidence files exist in `.sisyphus/evidence/`. Compare deliverables against plan.
  Output: `Must Have [N/N] | Must NOT Have [N/N] | Tasks [N/N] | VERDICT: APPROVE/REJECT`

- [ ] F2. **Code Quality Review** — `unspecified-high`
  Run `cargo fmt --all -- --check`, `cargo clippy --all-targets --all-features -- -D warnings`, `cargo test`. Review changed files for: `.unwrap()`/`.expect()` in prod code, missing `#[instrument]`, generic names, commented-out code, unused imports, missing skip() on instrument macros, key-as-label violations.
  Output: `Fmt [PASS/FAIL] | Clippy [PASS/FAIL] | Tests [N pass/N fail] | Files [N clean/N issues] | VERDICT`

- [ ] F3. **Real Manual QA** — `unspecified-high`
  Start from clean state (`docker run -p 6379:6379 redis:7` or equivalent). Execute EVERY QA scenario from EVERY task — exact steps, capture evidence. Test cross-task integration: flag-on generated project end-to-end (generate → check → test), duplicate-event flow through middleware + store + metrics. Edge cases: empty key, invalid charset, TTL bounds, Redis-down 503.
  Output: `Scenarios [N/N pass] | Integration [N/N] | Edge Cases [N tested] | VERDICT`

- [ ] F4. **Scope Fidelity Check** — `deep`
  For each task: read "What to do", read actual diff (`git log/diff`). Verify 1:1 — everything in spec built, nothing beyond spec built. Check "Must NOT do" compliance (especially: no PG code, no tests/integration/ changes, no dependency additions). Flag unaccounted changes.
  Output: `Tasks [N/N compliant] | Contamination [CLEAN/N issues] | Unaccounted [CLEAN/N files] | VERDICT`

---

## Commit Strategy

- **T0**: `docs(specs): reconcile 001 idempotency artifacts with locked decisions` — specs/001-idempotency-guard/*
- **T1**: `feat(idempotency): core module — key validation, store trait, guard RAII` — src/idempotency/{mod,key,error,store,guard}.rs
- **T2**: `feat(idempotency): redis store — NX/EX acquire, owner-token release, completed marker` — src/idempotency/redis_store.rs
- **T3**: `feat(idempotency): config, AppState wiring, error responses` — src/config.rs, src/state.rs, src/main.rs, src/idempotency/error.rs, config/*.toml
- **T4**: `feat(idempotency): event ingest middleware on POST /` — src/middleware.rs, src/routes.rs
- **T5**: `feat(idempotency): metrics and tracing instrumentation` — src/observability.rs, src/idempotency/*
- **T6**: `test(idempotency): redis integration, concurrency, property tests` — tests/idempotency_*.rs
- **T7**: `feat(template): gate idempotency behind feature_idempotency flag` — cargo-generate.toml, .github/workflows/*
- **T8**: `docs(idempotency): AGENTS.md section and configuration reference` — AGENTS.md, README.md.liquid
- Pre-commit per commit: `cargo fmt --all && cargo clippy --all-targets --all-features -- -D warnings && cargo test`

## Success Criteria

### Verification Commands
```bash
cargo fmt --all -- --check                                # Expected: clean
cargo clippy --all-targets --all-features -- -D warnings  # Expected: no warnings
cargo test                                                # Expected: all pass (unit/property/concurrency)
cargo test -- --ignored                                   # Expected: all pass (requires local Redis)
cargo generate --path . --name idem-on --define feature_idempotency=true   # Expected: generates; project compiles
cargo generate --path . --name idem-off --define feature_idempotency=false # Expected: grep -ri idempotency → 0 hits in generated src/
```

### Final Checklist
- [ ] All "Must Have" present
- [ ] All "Must NOT Have" absent
- [ ] All tests pass (incl. `-- --ignored` with Redis)
- [ ] FR-001..010 satisfied (FR-004 deferred by design, documented)
- [ ] Evidence files present in `.sisyphus/evidence/`
