# Tasks: Kafka Event Publishing from Handlers

**Feature**: Kafka Event Publishing from Handlers  
**Branch**: `002-kafka-event-publishing`  
**Status**: Phase 6 (Distributed Tracing & Metrics) Complete | **Date**: 2026-01-04

---

## Overview

This document contains all implementation tasks for adding optional Kafka event publishing capabilities to the Rust Knative Flux template. Tasks are organized by user story (priority P1, P2) with clear dependencies and parallel execution opportunities.

### Task Statistics

- **Total Tasks**: 48
- **Phase 1 (Setup)**: 5 tasks
- **Phase 2 (Foundational)**: 8 tasks
- **Phase 3 (US1: Generation-Time Configuration)**: 2 tasks
- **Phase 4 (US2: Publish Dummy Events)**: 14 tasks
- **Phase 5 (US3: Graceful Failure Handling)**: 5 tasks
- **Phase 6 (US4: Distributed Tracing)**: 3 tasks
- **Phase 7 (Polish & Cross-Cutting)**: 11 tasks

### User Story Priority Order

1. **US1 (P1)**: Configure Kafka Event Publishing at Generation Time
2. **US2 (P1)**: Publish Dummy Events from HTTP Handlers
3. **US3 (P2)**: Handle Kafka Publishing Failures Gracefully
4. **US4 (P2)**: Observe Event Publishing with Distributed Tracing

### Parallel Opportunities

- **Phase 3**: All configuration-related tasks (T006-T015) can be completed in parallel after T005
- **Phase 4**: CloudEvent generation (T016-T018), KafkaPublisher implementation (T019-T025), and handler integration (T026-T029) are independent after T014
- **Phase 5**: Error handling tasks (T030-T034) depend on Phase 4 completion
- **Phase 6**: Tracing tasks (T035-T037) can begin after T019

### MVP Scope (Recommended)

**Minimum Viable Product**: Phase 1 + Phase 2 + Phase 3 + Phase 4 (US1 + US2)
- Enables basic feature: Kafka publishing from handlers with generation-time config
- Acceptance tests verify dummy events appear in Kafka topic
- Estimated scope: 24 tasks (T001-T029)
- Can be extended with error handling (US3) and tracing (US4) later

**Suggested First Increment**: 
1. Complete Phase 1 (Setup): T001-T005
2. Complete Phase 2 (Foundational): T006-T013
3. Complete Phase 3 (US1 configuration): T014-T015
4. Test generation flow with `cargo generate`
5. Then move to Phase 4 (US2 publishing)

---

## Phase 1: Project Initialization & Setup

**Goal**: Prepare development environment and verify prerequisites

**Independent Test**: `cargo build` succeeds with new dependencies added

### Tasks

- [x] T001 Create feature branch and update git configuration for `002-kafka-event-publishing` branch tracking
- [x] T002 Update Cargo.toml.liquid to add rdkafka dependency with cmake-build and tracing features: `rdkafka = { version = "0.38", features = ["cmake-build", "tracing"] }`
- [x] T003 Add cloudevents-sdk crate as optional dependency in Cargo.toml.liquid: `cloudevents = { version = "0.6", optional = true }` (for future CloudEvents schema validation)
- [x] T004 Verify axum-cloudevents vendored crate in crates/axum-cloudevents/ is compatible with CloudEvent struct export, update crates/axum-cloudevents/src/lib.rs if needed to re-export CloudEvent type
- [x] T005 Run `cargo build` and `cargo clippy` to verify all dependencies resolve and compile correctly

---

## Phase 2: Foundational Infrastructure

**Goal**: Implement core configuration loading and error handling that all user stories depend on

**Independent Test**: Configuration loads from all three tiers (env vars, TOML files, defaults), validation works

### Tasks

- [x] T006 Create src/error.rs KafkaError enum with 7 variants (InitializationFailed, PublishFailed, SerializationFailed, BrokerUnreachable, InvalidConfiguration, TopicNotFound, Internal) using `#[derive(Error, Debug)]` and `thiserror` crate
- [x] T007 Implement IntoResponse trait for KafkaError in src/error.rs to convert errors to HTTP 500 responses with JSON error details
- [x] T008 Create KafkaConfig struct in src/config.rs.liquid with fields: broker_url (required), topic (required), event_name (required), compression (default "snappy"), linger_ms (default 5), retries (default 3), timeout_ms (default 10000), using `#[derive(Deserialize, Serialize)]`
- [x] T009 Implement KafkaConfig::validate() in src/config.rs.liquid with validation for required fields, CloudEvents type format (event_name), compression enum, linger_ms range (0-60000), timeout_ms range (1000-300000)
- [x] T010 Add KafkaConfig as optional field in AppConfig struct: `pub kafka: Option<KafkaConfig>` in src/config.rs.liquid
- [x] T011 Update config loading in src/config.rs.liquid to load [kafka] section from TOML files via figment with environment variable prefix `APP__KAFKA__`
- [x] T012 Create config/default.toml.liquid with [kafka] section (conditional on kafka feature flag): broker_url, topic, event_name, compression, linger_ms, retries, timeout_ms with sensible dev defaults
- [x] T013 Create/update config/development.toml.liquid and config/production.toml.liquid with environment-specific [kafka] overrides (shorter timeout for dev, longer for prod)

---

## Phase 3: User Story 1 - Configure Kafka Event Publishing at Generation Time

**Goal**: Enable users to configure Kafka publishing during template generation via cargo-generate prompts

**Acceptance Criteria**:
1. Users can enable/disable Kafka publishing with yes/no prompt (default: no)
2. When enabled, users provide broker_url, topic, event_name
3. Generated project contains Kafka dependencies only if enabled
4. Configuration values appear in generated config/*.toml files
5. Disabling Kafka excludes all Kafka code via Liquid template conditionals

**Independent Test**: 
```bash
cargo generate --git <repo> --name test-service <<EOF
test-service
n  # no s3
y  # yes kafka
kafka.kafka.svc.cluster.local:9092
my-events
com.example.test.event.published
n  # no image updates
default
myorg
test-service
main
EOF
# Verify: Cargo.toml has rdkafka, config files have [kafka] section, Kafka code exists
```

**Story Tasks**:

- [x] T014 [US1] Update cargo-generate.toml with three new prompts: enable_kafka_publishing (bool, default false), kafka_broker_url (string with conditional when enable_kafka_publishing==true), kafka_topic, kafka_event_name
- [x] T015 [US1] Add Liquid template conditionals to config/default.toml.liquid, config/development.toml.liquid, config/production.toml.liquid to conditionally include [kafka] sections using `{% if enable_kafka_publishing %}...{% endif %}` with {{kafka_broker_url}}, {{kafka_topic}}, {{kafka_event_name}} placeholders

---

## Phase 4: User Story 2 - Publish Dummy Events from HTTP Handlers

**Goal**: Implement core publishing functionality - handlers publish dummy CloudEvents to Kafka on invocation

**Acceptance Criteria**:
1. CloudEvent is generated with all required fields (specversion, type, source, id, time)
2. Event published asynchronously (non-blocking) via tokio::spawn()
3. Event appears in Kafka topic within 1 second
4. Multiple rapid requests each generate unique event IDs
5. Publishing latency <100ms average (measured via metrics)

**Independent Test**:
```bash
# Start Kafka broker
docker-compose up -d kafka

# Build generated service with kafka enabled
cargo build

# Start service
RUST_LOG=info cargo run

# In another terminal:
# Make HTTP request
curl http://localhost:8080/api/v1/hello?name=test

# Verify event in Kafka
kafka-console-consumer --bootstrap-server localhost:9092 --topic my-events --from-beginning --max-messages 1
# Expected: JSON CloudEvent with type=com.example.test.event.published, source=/api/v1/hello, id=<uuid>
```

**Story Tasks**:

- [x] T016 [P] [US2] Create CloudEvent struct in src/handlers/kafka.rs.liquid (or extend axum-cloudevents) with fields: specversion ("1.0"), type_, source, id, time, data (Option), datacontenttype (Option), traceparent (Option), using serde JSON serialization
- [x] T017 [P] [US2] Implement create_dummy_event() function in src/handlers/kafka.rs.liquid that generates CloudEvent with event_name from config, handler_path as source, UUID as id, current UTC timestamp, minimal dummy data payload
- [x] T018 [P] [US2] Add CloudEvent JSON serialization tests in src/handlers/kafka.rs.liquid: verify specversion="1.0", type matches event_name, source matches path, id is valid UUID, time is ISO 8601
- [x] T019 [P] [US2] Implement KafkaPublisher struct in src/handlers/kafka.rs.liquid with fields: producer (Arc<FutureProducer>), config (Arc<KafkaConfig>), using #[instrument] macro for #[derive] visibility
- [x] T020 [P] [US2] Implement KafkaPublisher::new() async constructor that initializes rdkafka FutureProducer with config settings (bootstrap_servers, compression, linger_ms, request_timeout_ms) using ClientConfig, return Result<Self, KafkaError>
- [x] T021 [P] [US2] Implement KafkaPublisher::publish() async method that: serializes CloudEvent to JSON, creates FutureRecord with event.id() as partition key, calls producer.send_result().await, returns Result<(i32, i64), KafkaError> with partition and offset
- [x] T022 [US2] Implement KafkaPublisher::health_check() async method that verifies broker connectivity (simple metadata fetch), return Result<(), KafkaError>
- [x] T023 [US2] Update AppState in src/state.rs.liquid to add kafka_publisher field: `pub kafka_publisher: Option<Arc<KafkaPublisher>>` using Liquid template conditional `{% if enable_kafka_publishing %}...{% endif %}`
- [x] T024 [US2] Update app initialization in src/main.rs.liquid to create KafkaPublisher from AppConfig::kafka if Some, call validate(), verify broker connectivity (fail fast if unreachable per CL-003), initialize publisher, add to AppState
- [x] T025 [US2] Update src/handlers/mod.rs.liquid to conditionally export kafka module using Liquid template: `{% if enable_kafka_publishing %}pub mod kafka;{% endif %}` (no Cargo feature flags)
- [x] T026 [US2] Update existing handler (src/handlers/api.rs - hello endpoint) to publish dummy event when Kafka enabled: extract publisher from State, call create_dummy_event(), spawn async task with tokio::spawn() to call publisher.publish(), return 200 OK immediately
- [x] T027 [US2] Update existing handler (src/handlers/storage.rs if S3 enabled) to publish dummy event on successful storage operation using same pattern as T026
- [x] T028 [US2] Create integration test in tests/integration/kafka_publishing_test.rs.liquid using testcontainers for embedded Kafka broker: auto-detect Docker availability and skip with warning if unavailable (per CL-004), start broker, initialize service with config, call handler, verify event in topic, verify event structure
- [x] T029 [US2] Create E2E test script tests/e2e/scripts/kafka-test.sh.liquid that: deploys service to Kind cluster via Kustomize, waits for readiness, makes HTTP requests, consumes from Kafka topic, verifies event fields

---

## Phase 5: User Story 3 - Handle Kafka Publishing Failures Gracefully

**Goal**: Ensure Kafka publishing failures don't prevent HTTP responses and are properly logged

**Acceptance Criteria**:
1. HTTP handler returns 200 OK even when Kafka broker unavailable
2. Publishing failures logged at ERROR level with context (broker, topic, event ID, reason)
3. Service doesn't enter permanently failed state (retry on next request)
4. Multiple failures all logged (not silently ignored)

**Independent Test**:
```bash
# Start service with Kafka config but don't start broker
cargo run --env RUST_LOG=error

# Make HTTP requests
for i in {1..5}; do curl http://localhost:8080/api/v1/hello; done

# Verify: All requests return 200 OK, logs show errors with context
# Kill kafka and restart it
# Make more requests - should succeed when broker comes back
```

**Story Tasks**:

- [x] T030 [US3] Update KafkaPublisher::publish() to return Result with KafkaError variants (PublishFailed, SerializationFailed, BrokerUnreachable based on rdkafka error code)
- [x] T031 [US3] Update handler publishing logic in src/handlers/api.rs and src/handlers/storage.rs to catch errors in spawned tokio::spawn() task and log via `tracing::error!(error = %e, broker = %broker_url, topic = %topic, event_id = %event_id, "Failed to publish event")` per NFR-002
- [x] T032 [US3] Add KafkaError::BrokerUnreachable variant with structured context fields (broker: String, reason: String) and Display impl that includes context
- [x] T033 [US3] Remove startup health_check() call per CL-003 (fail fast already handled in T024); instead update readiness probe logic if needed to reflect Kafka publisher state
- [x] T034 [US3] Add integration test in tests/integration/kafka_publishing_test.rs to simulate broker unavailability: auto-detect Docker (skip with warning if unavailable per CL-004), disconnect broker, make requests, verify 200 OK returned and errors logged, reconnect broker, verify requests succeed

---

## Phase 6: User Story 4 - Observe Event Publishing with Distributed Tracing

**Goal**: Add observability (tracing spans, metrics) to event publishing operations

**Acceptance Criteria**:
1. Publishing operation creates span with event ID and topic recorded
2. Span duration reflects actual publish latency
3. Failed operations include error details in span
4. Traces show proper parent-child relationships in Jaeger
5. B3 header propagation enables cross-service correlation

**Independent Test**:
```bash
# Start Jaeger locally
docker-compose up -d jaeger

# Configure service with OTLP
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317

cargo run

# Make HTTP requests
curl http://localhost:8080/api/v1/hello

# View in Jaeger UI (http://localhost:16686)
# Search for service: test-service, operation: hello
# Verify: Child span for kafka_publish with event_id field, duration <100ms
```

**Story Tasks**:

- [x] T035 [US4] Add #[instrument(skip(self, event), fields(event_id = %event.id(), topic = %topic))] macro to KafkaPublisher::publish() method in src/handlers/kafka.rs.liquid for automatic span creation with event ID and topic fields
- [x] T036 [US4] Add metrics to observability in src/observability.rs: `counter!("kafka_events_published_total")`, `counter!("kafka_events_failed_total")`, `histogram!("kafka_publish_latency_ms")` using metrics crate
- [x] T037 [US4] Update KafkaPublisher::publish() to increment success/failure metrics and record latency histogram after rdkafka send_result completes

---

## Phase 7: Polish & Cross-Cutting Concerns

**Goal**: Testing, documentation, and final validation

**Independent Test**: All tests pass, documentation is complete

### Tasks

- [ ] T038 Verify Docker build works with Kafka enabled: run `docker build -t template:latest .` on generated project with kafka_enabled=true, verify image builds successfully (per CL-001)
- [ ] T039 Run full test suite: `cargo test --all-features -- --ignored` (includes unit, integration, E2E from previous phases)
- [ ] T040 Run linting and formatting checks: `cargo fmt --all -- --check && cargo clippy --all-targets --all-features -- -D warnings`
- [ ] T041 Update docs/KAFKA_EVENTING.md with publishing patterns section: add examples of KafkaPublisher usage, non-blocking pattern, error handling, configuration, reference to this feature implementation
- [ ] T042 Update AGENTS.md with Kafka publishing patterns: add examples of publish from handlers, explain #[instrument] usage for Kafka operations, cold start impact notes
- [ ] T043 Create CLOUDEVENTS_KAFKA_PUBLISHING.md reference guide with complete examples: simple handler publishing, batch-like scenario (multiple handlers), testing with testcontainers, production deployment checklist
- [ ] T044 Update README.md section on Kafka to mention publishing support: link to quickstart.md and reference documentation
- [ ] T045 Verify git status clean except for generated files, run `git diff` to review all changes against spec
- [ ] T046 Create commit message per Conventional Commits: `feat(kafka): add event publishing from handlers with Liquid template conditionals`
- [ ] T047 Update CHANGELOG.md with feature summary, related PRs, breaking changes (none), migration guide (none, backward compatible with default disabled)
- [ ] T048 Tag for release or squash commits for PR (dependent on workflow preference)

---

## Dependencies & Execution Order

### Critical Path (Blocking Dependencies)

```
T001-T005 (Setup)
    ↓
T006-T013 (Foundational config/error)
    ↓
T014-T015 (US1 generation-time config)
    ↓
T016-T029 (US2 publishing implementation)
    ↓
T030-T034 (US3 error handling)
    ↓
T035-T037 (US4 tracing/metrics)
    ↓
T038-T047 (Polish & docs)
```

### Parallelizable Task Groups (within phases)

**Within Phase 2 (T006-T013)**:
- T006 (KafkaError) and T008-T012 (KafkaConfig) can run in parallel after T005
- T007 (IntoResponse) depends on T006

**Within Phase 4 (T016-T029)**:
- T016-T018 (CloudEvent generation/tests) independent
- T019-T022 (KafkaPublisher implementation) independent
- T023-T025 (AppState integration) can start after T021
- T026-T029 (Handler integration + tests) independent, start after T025

**Example Parallel Execution Timeline**:
1. Complete Phase 1 sequentially: T001-T005 (~2 hours)
2. Execute Phase 2 with parallelization: 
   - Thread A: T006 → T007
   - Thread B: T008 → T012, T013
   - Merge after both complete (~3 hours)
3. Execute Phase 3 (small, sequential): T014-T015 (~1 hour)
4. Execute Phase 4 with heavy parallelization:
   - Thread A: T016-T018 (CloudEvent)
   - Thread B: T019-T022 (KafkaPublisher)
   - Thread C: T026-T027 (Handler integration) [starts after T025 from Thread B]
   - Thread D: T028-T029 (Tests) [start after threads A & B complete]
   - Merge after all complete (~8 hours)

---

## Test Coverage by User Story

### US1: Configuration Generation
- Unit tests: T014 cargo-generate.toml validation
- Integration test: Generated project structure validation
- Manual test: `cargo generate` prompt flow

### US2: Dummy Event Publishing
- Unit tests: T018 CloudEvent serialization, T024 initialization
- Integration test: T028 testcontainers Kafka publishing
- E2E test: T029 Kind deployment + handler invocation
- Performance test: Verify <100ms latency via metrics

### US3: Graceful Failure Handling
- Integration test: T034 broker unavailability scenario
- Unit test: T032 KafkaError variants

### US4: Distributed Tracing
- Integration test: Jaeger span verification (manual, documented in T035-T037)
- Metrics test: prometheus scrape endpoint verification

---

## Implementation Notes

### MVP Delivery (Phases 1-4, Tasks T001-T029)

This provides the core feature: **Kafka event publishing from handlers with generation-time configuration and dummy events.**

- Users can enable Kafka during template generation
- Handlers automatically publish CloudEvents
- Events appear in configured Kafka topic
- Configuration via generation-time prompts + env var overrides
- Estimated effort: **15-20 hours**

### Full Feature (All Phases 1-7, Tasks T001-T047)

Adds production-ready capabilities:
- Error handling (US3): **+3-4 hours**
- Tracing/observability (US4): **+2-3 hours**
- Documentation/polish: **+4-5 hours**
- **Total estimated effort: 25-35 hours**

### Quality Gates

All tasks must satisfy:
1. ✅ Code formatting: `cargo fmt --all`
2. ✅ Linting: `cargo clippy --all-targets --all-features -- -D warnings`
3. ✅ Testing: `cargo test --all-features -- --ignored` (all must pass)
4. ✅ Constitution compliance: Observability (#[instrument]), configuration hierarchy, error handling (thiserror), performance (<500ms cold start)

---

## File Path Reference

| Component | File Path |
|-----------|-----------|
| Error types | src/error.rs |
| Configuration | src/config.rs.liquid |
| App state | src/state.rs.liquid |
| Kafka module | src/handlers/kafka.rs.liquid |
| Handler updates | src/handlers/api.rs, src/handlers/storage.rs |
| Observability | src/observability.rs |
| Main app init | src/main.rs.liquid |
| Config defaults | config/default.toml.liquid |
| Dev config | config/development.toml.liquid |
| Prod config | config/production.toml.liquid |
| Generation config | cargo-generate.toml |
| Unit tests | src/handlers/kafka.rs.liquid (#[cfg(test)]) |
| Integration tests | tests/integration/kafka_publishing_test.rs |
| E2E tests | tests/e2e/scripts/kafka-test.sh |
| Documentation | docs/KAFKA_EVENTING.md, AGENTS.md, README.md |

---

## Validation Checklist

- [ ] All 48 tasks follow strict checklist format (checkbox, ID, [P] if parallel, [Story] if applicable, description with file path)
- [ ] Task IDs sequential (T001-T048)
- [ ] All user story tasks labeled [US1], [US2], [US3], or [US4]
- [ ] File paths are absolute or well-known repo locations
- [ ] Dependencies clearly documented in "Dependencies & Execution Order" section
- [ ] Tests tied to specific tasks
- [ ] MVP scope clearly identified (T001-T029)
- [ ] Parallel opportunities marked with [P]
- [ ] Constitution compliance verified for all implementation tasks
- [ ] No circular dependencies

---

## Next Steps

1. **Review this tasks.md** with team to confirm scope and priorities
2. **Select starting point**: Begin with Phase 1 (T001-T005) or Phase 2 (T006-T013)
3. **Assign tasks** across team members, leveraging parallelization opportunities
4. **Track progress** in kanban or issue tracker, updating task status
5. **Run quality gates** frequently (formatting, clippy, tests)
6. **Validate against spec** after each phase completion
7. **Consider MVP release** after Phase 4 (T029), then iterate with P2 features

---

**Generated**: 2026-01-03 | **Status**: Ready for Implementation | **Branch**: `002-kafka-event-publishing`

---

## Clarifications Applied

The following clarifications from `spec.md` have been incorporated into these tasks:

| ID | Summary | Tasks Affected |
|----|---------|----------------|
| CL-001 | Docker build moved to Phase 7 (not T005) | T038 added |
| CL-002 | Liquid template conditionals only (no Cargo features) | T023, T025, T046 |
| CL-003 | Fail fast if broker unreachable at startup | T024, T033 |
| CL-004 | Auto-detect Docker, skip tests with warning | T028, T034 |
