# Executive Summary: CloudEvents + Kafka Integration Research

**Location**: `CLOUDEVENTS_KAFKA_RESEARCH.md` (916 lines)  
**Audience**: Development team planning Kafka event publishing feature  
**Status**: Complete research phase for spec `002-kafka-event-publishing`

---

## Key Findings

### 1. **CloudEvents Standard (v1.0) Compliance** ✅

- **Required fields**: `specversion`, `type`, `source`, `id` (+ optional `time`)
- **Serialization formats**: 
  - ✅ **JSON (Structured)** - Recommended for this template (simplest, most portable)
  - ⚠️ Protocol Buffers/Avro - Unnecessary complexity
- **Template requirements**: All published events must be RFC 3339 timestamps (ISO 8601 UTC)

### 2. **Rust CloudEvents Crates Comparison**

| Crate | Use Case | Verdict |
|-------|----------|---------|
| **`cloudevents-sdk` (v0.9+)** | Publishing events | ✅ RECOMMENDED |
| **`axum-cloudevents` (vendored)** | Consuming events | ✅ CURRENT (keep for consumption) |

**Recommendation**: Use `cloudevents-sdk` with `rdkafka` feature for publishing to match CNCF standards.

### 3. **Kafka Message Format (Structured Encoding)**

- **Single Kafka message contains**: Full CloudEvent as JSON value
- **Content-Type header**: `application/cloudevents+json`
- **Partition key strategy**: Use `event.id()` for deterministic placement + deduplication
- **Topic naming**: Single configurable topic; route by CloudEvent `type` field

**Example message**:
```json
{
  "specversion": "1.0",
  "type": "com.example.service.event.published",
  "source": "/api/handlers/ping",
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "time": "2025-01-03T15:30:45.123Z",
  "data": { "message": "handler invoked" }
}
```

### 4. **Template Integration Points** (10 files to modify)

**Configuration**:
- ✅ Add `KafkaConfig` to `src/config.rs.liquid`
- ✅ Extend `AppState` with `KafkaPublisher` (conditional)
- ✅ Add error variant: `AppError::KafkaPublish`

**Publishing**:
- ✅ New module: `src/handlers/kafka.rs.liquid` (conditional)
- ✅ Non-blocking pattern: `tokio::spawn` (don't block HTTP responses)
- ✅ Instrumentation: `#[instrument]` macro on all publish functions

**Testing**:
- ✅ Unit tests for CloudEvent serialization
- ✅ Integration tests with testcontainers Kafka
- ✅ E2E tests with Kind + Kubernetes

### 5. **Recommended Dependency Stack**

```toml
# Optional (feature = "kafka")
rdkafka = "0.36"                          # Kafka producer
cloudevents-sdk = { version = "0.9", features = ["rdkafka"] }

# Already available
uuid = { version = "1.0", features = ["v4", "serde"] }
chrono = { version = "0.4", features = ["serde"] }
tracing = "0.1"
tokio = { version = "1" }
```

### 6. **Error Handling Strategy: Graceful Degradation**

**Key pattern**: Publishing failures must NOT fail HTTP requests

```rust
// ✅ GOOD: Non-blocking publish with silent error logging
tokio::spawn(async move {
    if let Err(e) = state.kafka_publisher.publish(&event).await {
        tracing::error!(error = %e, "Failed to publish");
        // Handler already returned 200 OK
    }
});

// ❌ BAD: Publishing failure cascades to request failure
state.kafka_publisher.publish(&event).await?; // ← Causes handler to fail
```

### 7. **Configuration Hierarchy** (3-tier)

```
1. Defaults (config/default.toml.liquid)
   └─ APP__KAFKA__BROKER env var override
      └─ config/{env}.toml.liquid (dev/staging/prod)
```

### 8. **Distributed Tracing Integration**

- ✅ All publish operations create OpenTelemetry spans
- ✅ B3 header propagation (critical for Knative)
- ✅ Trace context correlation across HTTP → Kafka → Consumer

### 9. **Event Naming Convention**

- **Format**: `com.example.service.event.published` (reverse-domain)
- **Configurable at generation time** (user input)
- **Stored in**: `KafkaConfig::event_name`
- **Used in**: Every published CloudEvent's `type` field

### 10. **Testing Strategy**

| Level | Tool | Coverage |
|-------|------|----------|
| **Unit** | cargo test | CloudEvent serialization, config loading |
| **Integration** | testcontainers | Kafka producer with real Kafka instance |
| **E2E** | Kind + kubectl | Full handler → Kafka → consumer flow |

---

## Quick Decision Matrix

| Decision | Choice | Why |
|----------|--------|-----|
| **Kafka client library** | `rdkafka` (0.36+) | Production-ready, CNCF integration, excellent performance |
| **CloudEvents library** | `cloudevents-sdk` (0.9+) + `rdkafka` feature | Official CNCF, active maintenance, native Kafka support |
| **Encoding mode** | JSON Structured | Most portable; simplest serialization |
| **Publishing pattern** | Async (tokio::spawn) | Non-blocking; doesn't impact handler latency |
| **Error handling** | Graceful degradation | Publishing failures logged but don't fail HTTP requests |
| **Configuration** | Figment 3-tier | Consistent with existing template (env vars > TOML) |
| **Instrumentation** | `#[instrument]` macro | Native tracing integration; distributed tracing visibility |
| **Partition key** | `event.id()` | Deterministic placement; enables deduplication |
| **Topic strategy** | Single configurable topic | Simple; route by CloudEvent `type` field |

---

## Implementation Readiness

### Pre-Implementation (Phase 1 - Design)

Before coding, create:
- ✅ **Data model** (`specs/002-kafka-event-publishing/data-model.md`): KafkaConfig, CloudEvent schemas
- ✅ **API contracts** (`specs/002-kafka-event-publishing/contracts/`): JSON schemas for config + events
- ✅ **Quickstart** (`specs/002-kafka-event-publishing/quickstart.md`): Usage guide for users

### Implementation (Phase 2 - Code)

Generate from `tasks.md`:
- [ ] Add dependencies to `Cargo.toml.liquid`
- [ ] Implement `KafkaConfig` struct
- [ ] Implement `KafkaPublisher` abstraction
- [ ] Extend `AppState` with optional publisher
- [ ] Add error handling (`KafkaError`)
- [ ] Create publishing handlers
- [ ] Add metrics/instrumentation
- [ ] Write unit tests
- [ ] Write integration tests
- [ ] Write E2E tests
- [ ] Update Dockerfile for rdkafka C libraries
- [ ] Update deployment manifests

---

## Critical Implementation Constraints

1. **Non-blocking**: Publish operations must not block HTTP handler execution
2. **Graceful failure**: Kafka unavailability must not cause service outages
3. **Knative compliance**: Port 8080, B3 propagation, SIGTERM handling (existing)
4. **Cold start**: Publishing feature must not add >500ms to startup time
5. **Configuration**: Must support generation-time + runtime configuration changes

---

## References

- Full research: `CLOUDEVENTS_KAFKA_RESEARCH.md`
- Feature spec: `specs/002-kafka-event-publishing/spec.md`
- Implementation plan: `specs/002-kafka-event-publishing/plan.md`
- Official CloudEvents: https://cloudevents.io/
- Kafka protocol binding: https://github.com/cloudevents/spec/blob/main/cloudevents/bindings/kafka-protocol-binding.md
- SDK Rust repo: https://github.com/cloudevents/sdk-rust
