# Feature Specification: Kafka Event Publishing from Handlers

**Feature Branch**: `002-kafka-event-publishing`  
**Created**: 2026-01-03  
**Status**: Draft  
**Input**: User description: "Add optional feature for Kafka event publishing from handlers. Should ask for broker URL, topic name, and event name. If enabled, publish a dummy event to the topic on handler hit. Use existing patterns of features=[s3, postgres]"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Configure Kafka Event Publishing at Generation Time (Priority: P1)

As a developer generating a new service from the template, I need to optionally enable Kafka event publishing capabilities during project generation, so that I can specify how my service should publish events without modifying code after generation.

**Why this priority**: This is foundational for the feature. Without configuration at generation time, the feature cannot be used. This represents the minimum viable product and the primary entry point for users.

**Independent Test**: Run `cargo generate` with the template, answer "yes" to the Kafka publishing feature prompt, provide broker URL, topic name, and event name during generation, then verify that the generated project includes Kafka publishing configuration and dependencies.

**Acceptance Scenarios**:

1. **Given** a user is generating a new project from the template, **When** they are prompted about Kafka event publishing features, **Then** they can answer "yes" or "no" to enable the feature (defaulting to "no" to maintain backward compatibility).
2. **Given** a user selects "yes" for Kafka event publishing, **When** prompted for configuration values, **Then** they must provide: broker URL (e.g., "kafka.kafka.svc.cluster.local:9092"), topic name (e.g., "events"), and event name (e.g., "service.event.published").
3. **Given** a user provides configuration values, **When** the project is generated, **Then** the generated Cargo.toml includes Kafka publishing dependencies and environment-specific config files contain the provided values.
4. **Given** Kafka publishing is disabled, **When** the project is generated, **Then** Kafka publishing code and dependencies are not included, keeping the binary smaller.

---

### User Story 2 - Publish Dummy Events from HTTP Handlers (Priority: P1)

As a developer, I need my HTTP handlers to publish dummy events to Kafka when they are called, so that I can test event publishing integration without implementing custom business logic.

**Why this priority**: This delivers the core value of the feature. Once enabled, users immediately get functional event publishing. This can be tested independently with just a working Kafka cluster.

**Independent Test**: Start a Kafka cluster, deploy the generated service with Kafka publishing enabled, make HTTP requests to a handler (e.g., GET /api/v1/hello), and verify that dummy events appear in the configured Kafka topic with the specified event name.

**Acceptance Scenarios**:

1. **Given** a service with Kafka publishing enabled and a running Kafka broker, **When** an HTTP handler is invoked, **Then** a CloudEvents-formatted dummy event is published to the configured Kafka topic.
2. **Given** an HTTP handler receives a request, **When** the handler processes the request, **Then** the event is published asynchronously (non-blocking) so that publishing failures do not prevent the HTTP response.
3. **Given** a dummy event is published, **When** the event appears in Kafka, **Then** it includes: required CloudEvents fields (specversion, type, source, id, time), the configured event name in the `type` field, the handler path in the `source` field, and a unique event ID.
4. **Given** multiple HTTP requests are made to the handler in rapid succession, **When** events are published to Kafka, **Then** each event has a unique ID and can be individually tracked.

---

### User Story 3 - Handle Kafka Publishing Failures Gracefully (Priority: P2)

As a developer, I need the service to handle Kafka publishing failures gracefully without crashing or breaking the HTTP response, so that temporary Kafka unavailability does not cause service outages.

**Why this priority**: This ensures production reliability. Once basic publishing works (P1), error handling prevents cascading failures. This can be tested independently from the core publishing functionality.

**Independent Test**: Stop or disconnect the Kafka broker while the service is running, make HTTP requests to handlers with Kafka publishing enabled, verify that requests still succeed and return valid HTTP responses, and confirm that failures are logged with actionable error information.

**Acceptance Scenarios**:

1. **Given** a service with Kafka publishing enabled, **When** the Kafka broker is unavailable, **Then** the HTTP handler request still succeeds and returns the normal HTTP response (e.g., 200 OK).
2. **Given** a Kafka publishing attempt fails, **When** the failure occurs, **Then** the error is logged with context (broker address, topic, reason for failure) at the ERROR level for operational visibility.
3. **Given** a publishing failure occurs, **When** the next request arrives, **Then** the service attempts to publish the new event (does not enter a permanently failed state).
4. **Given** persistent Kafka failures, **When** multiple events fail to publish, **Then** logs include all failures and provide guidance for operators (e.g., "Kafka broker unreachable at kafka:9092").

---

### User Story 4 - Observe Event Publishing with Distributed Tracing (Priority: P2)

As an operator, I need visibility into event publishing operations through distributed tracing and metrics, so that I can monitor the health of event publishing and troubleshoot integration issues.

**Why this priority**: Observability enables operational excellence and troubleshooting. Once basic publishing works (P1) and failures are handled (P2), adding observability provides production-ready capabilities. This can be tested independently.

**Independent Test**: Enable distributed tracing (OpenTelemetry), make HTTP requests to handlers with Kafka publishing enabled, view traces in Jaeger, and verify that event publishing operations create spans with proper context propagation.

**Acceptance Scenarios**:

1. **Given** a service with Kafka publishing enabled and OTLP configured, **When** an HTTP handler publishes an event, **Then** a span is created for the publishing operation with the event ID and topic name recorded.
2. **Given** a Kafka publishing operation, **When** the operation is traced, **Then** the span duration reflects the actual time spent publishing (including network round-trip time).
3. **Given** a publishing failure, **When** the operation is traced, **Then** the span includes error details (exception type, message) that aid in troubleshooting.
4. **Given** multiple handlers publishing events, **When** traces are viewed in Jaeger, **Then** each event publishing operation is visible as a child span of the HTTP request span with proper correlation.

---

### Edge Cases

- What happens when the Kafka broker connection is established during startup but the broker becomes unavailable after the service is running? The service should attempt to reconnect on the next publishing attempt rather than crashing.
- What happens when the configured Kafka topic does not exist? The publishing attempt should fail gracefully and log the error; topic auto-creation behavior depends on Kafka cluster configuration.
- How are timestamps handled if the service clock differs from the Kafka broker clock? All timestamps in CloudEvents should be generated by the service using its local system clock (ISO 8601 format) for consistency.
- What happens if the event name contains invalid characters for CloudEvent type fields? Configuration validation at startup should reject invalid event names and guide the user to a valid format (e.g., "com.company.service.event.published").
- What happens when "kafka" is not selected in the features array? The service simply does not include Kafka publishing capabilities; handlers that would publish events are not generated in the template (conditional Liquid template logic with `{% if "kafka" in features %}`).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The template MUST include Kafka in the `features` multi-select prompt during generation (alongside S3, PostgreSQL, and other optional features).
- **FR-002**: When Kafka is selected in the features array, the template MUST prompt for: broker URL (e.g., "kafka.kafka.svc.cluster.local:9092"), topic name (e.g., "events"), and event name (e.g., "service.event.published").
- **FR-003**: The generated project MUST include Kafka client libraries and publishing dependencies only when "kafka" is present in the `features` array.
- **FR-004**: When "kafka" is in the features array, the template MUST generate HTTP handlers (or handler implementations) that publish dummy CloudEvents-formatted events to the configured Kafka topic using conditional Liquid template logic (`{% if "kafka" in features %}`).
- **FR-005**: Each published event MUST include CloudEvents required fields: specversion (1.0), type (set to configured event name), source (HTTP handler path), id (unique event identifier), time (ISO 8601 timestamp).
- **FR-006**: Event publishing MUST be non-blocking (asynchronous) so that Kafka publishing failures do not prevent HTTP response delivery.
- **FR-007**: Kafka broker connection configuration MUST be externalized via environment variables with `APP__KAFKA__*` prefix and configuration files.
- **FR-008**: The service MUST support both local Kafka (via Kind for development) and external Kafka brokers (configured via environment variables for staging/production).
- **FR-009**: When "kafka" is not in the features array, the template MUST not include Kafka dependencies, publishing code, or handlers that publish events (determined by conditional Liquid template logic).
- **FR-010**: Configuration validation MUST occur at startup; the service MUST fail fast if "kafka" is in features but broker URL or topic name are empty.

### Non-Functional Requirements

- **NFR-001**: All Kafka publishing operations MUST be instrumented with `#[instrument]` macro for distributed tracing visibility.
- **NFR-002**: All Kafka publishing errors MUST be logged with context (broker address, topic, event ID, error reason) at the ERROR level before returning to handler.
- **NFR-003**: Kafka publishing operations MUST NOT block the HTTP request handling path (async/non-blocking pattern).
- **NFR-004**: Event publishing MUST support B3 header propagation for trace correlation across Kafka and HTTP boundaries.
- **NFR-005**: Publishing latency SHOULD be <100ms on average (local Kafka) to avoid noticeable impact on HTTP response times.
- **NFR-006**: Configuration MUST follow the existing 3-tier hierarchy: environment variables > environment-specific TOML files > defaults.
- **NFR-007**: Error handling MUST use `thiserror` and `IntoResponse` patterns consistent with existing codebase.
- **NFR-008**: Kafka publisher MUST support connection pooling/multiplexing similar to Redis for efficient resource usage.
- **NFR-009**: Service startup time SHOULD not increase by more than 500ms when Kafka publishing is enabled (Knative cold start constraint).

### Key Entities

- **KafkaPublisher**: A client abstraction for publishing events to Kafka with configuration for broker address, topic, and retry behavior.
- **CloudEvent**: A published event in CloudEvents 1.0 format with type, source, id, specversion, and timestamp fields.
- **KafkaConfig**: Configuration entity containing broker URL, topic name, and event name provided at generation and runtime.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Users can enable Kafka event publishing during template generation by answering prompts and providing required configuration values.
- **SC-002**: Generated services with Kafka publishing enabled successfully publish a CloudEvents-formatted event to Kafka on each HTTP handler invocation within 100ms on average.
- **SC-003**: Event publishing failures (e.g., broker unavailable) do not prevent HTTP responses; handlers continue to return 200 OK even when Kafka is unreachable.
- **SC-004**: Published events are visible in Kafka topics within 1 second of handler invocation and include all required CloudEvents fields.
- **SC-005**: Services with Kafka publishing enabled have cold startup time under 3 seconds (within Knative constraints), representing <500ms additional overhead compared to baseline.
- **SC-006**: Event publishing operations create distributed traces visible in Jaeger that include span name, duration, and error details when failures occur.
- **SC-007**: Configuration at generation time matches configuration at runtime; changes to environment variables correctly override generated defaults.

## Implementation Constraints & Assumptions

### Assumptions

- Users have a working Kafka cluster available (local Kind deployment for dev, managed Kafka for staging/prod).
- Generated services will use synchronous publishing pattern initially (fire-and-forget with async error handling), not acknowledgment-based patterns.
- Dummy events are simple test events with minimal payload to demonstrate publishing; production event schema is developer responsibility.
- Event names follow CloudEvents type field conventions (reverse-domain notation recommended, e.g., "com.company.service.event.published").
- Kafka dependency choice is rdkafka or tokio-kafka based on performance/stability trade-offs (decision deferred to planning phase).
- Configuration at generation time is persisted in `config/{env}.toml` files and can be overridden via `APP__KAFKA__*` environment variables.

### Out of Scope

- Multi-topic publishing (single configured topic per service; multiple topics requires separate service instances).
- Event schema validation or schema registry integration (CloudEvents structure only).
- Kafka consumer functionality (this spec covers publishing only; consuming is separate).
- Kafka cluster deployment or infrastructure (assumed to exist; only client configuration covered).
- Custom event payload generation (dummy events only; production payloads are developer responsibility).
- Batch event publishing or transaction patterns (single event per handler invocation).
- Backpressure or flow control mechanisms (async fire-and-forget pattern assumed).

## Clarifications

### CL-001: Docker Build Verification (2026-01-03)
**Question**: Should T005 include Docker build verification?  
**Answer**: No. T005 remains cargo-only (`cargo build`, `cargo clippy`). Docker build verification moves to Polish phase (T038-T047) as a separate task.

### CL-002: Feature Flag Strategy (2026-01-03)
**Question**: How should Kafka code be conditionally included/excluded?  
**Answer**: Use **Liquid template conditionals only** (`{% if kafka_enabled %}`). The generated project should NOT use Cargo feature flags for Kafka. When user answers "no" during `cargo generate`, Kafka code, dependencies, and config are simply not rendered into the generated project. This follows the cargo-generate template pattern, not runtime feature toggles.

### CL-003: Kafka Broker Startup Behavior (2026-01-03)
**Question**: When Kafka is enabled with valid config but broker is unreachable at startup, what should happen?  
**Answer**: **Fail fast**. The service should validate broker connectivity at startup and fail to start if the broker is unreachable. This provides immediate feedback on misconfiguration and aligns with FR-010's intent. Knative will handle pod restart retries. Error message should be clear: "Kafka broker unreachable at {broker_url}".

### CL-004: Test Execution Without Docker (2026-01-03)
**Question**: How should integration tests behave when Docker is unavailable?  
**Answer**: **Auto-detect Docker**. Integration tests should check for Docker availability at runtime and skip gracefully with a warning if Docker is not available. This allows `cargo test` to run all available tests in a single command, with integration tests automatically skipped when Docker is unavailable. Warning message should indicate: "Skipping Kafka integration tests: Docker not available".

### CL-005: Feature Selection Mechanism (2026-01-05)
**Question**: How should Kafka be selected during template generation - as a separate boolean prompt or as part of a features array?  
**Answer**: Use **features array pattern** (`features = ["s3", "postgres", "kafka"]`). Kafka should be included in the existing `features` multi-select prompt in `cargo-generate.toml`, aligned with how S3 and PostgreSQL are already handled. Liquid template conditionals should check `{% if "kafka" in features %}` instead of `{% if enable_kafka_publishing %}`. This provides consistent UX, single prompt for all optional features, and aligns with existing template patterns.

## Related Documentation

- See `docs/KAFKA_EVENTING.md` for existing Knative Eventing (consumer) documentation; this feature adds publisher capabilities.
- See `cargo-generate.toml` for existing feature template configuration patterns.
- See `src/config.rs` for configuration loading patterns with figment 3-tier hierarchy.
