# CloudEvents + Kafka Integration: Quick Reference

**For detailed guidance, see**: `CLOUDEVENTS_KAFKA_RESEARCH.md` and `CLOUDEVENTS_KAFKA_RESEARCH_SUMMARY.md`

---

## 1-Minute Overview

**Goal**: Enable Kafka event publishing from HTTP handlers using CloudEvents standard  
**Stack**: `rdkafka` + `cloudevents-sdk` + existing Axum/Tokio  
**Pattern**: Async, non-blocking publish (doesn't delay HTTP responses)  
**Config**: Generation-time + environment variables (figment 3-tier hierarchy)

---

## CloudEvents: What's Required?

Every published event MUST have:

```json
{
  "specversion": "1.0",              // Always "1.0"
  "type": "com.example.event.type",  // User-configured at generation
  "source": "/api/handler/path",     // Handler that triggered it
  "id": "550e8400-e29b-41d4...",     // Unique UUID per event
  "time": "2025-01-03T15:30:45.123Z" // ISO 8601 UTC timestamp
}
```

---

## Kafka Protocol: What Format?

**Use**: JSON Structured Content Mode
- Full CloudEvent (metadata + data) serialized as JSON
- Goes into Kafka message **value**
- Message **key** = `event.id()` (for partitioning)
- Content-Type header = `application/cloudevents+json`

```
Kafka Topic: events (configurable)
├─ Key: 550e8400-e29b-41d4-a716-446655440000
└─ Value: {
    "specversion": "1.0",
    "type": "com.example.event.type",
    ...
   }
```

---

## Publishing Pattern: What Code?

**Handler (non-blocking)**:

```rust
#[instrument]
pub async fn handler(State(state): State<AppState>) -> Json<Response> {
    // 1. Prepare response immediately
    let response = Json(Response { success: true });
    
    // 2. Spawn background task for publishing (non-blocking)
    #[cfg(feature = "kafka")]
    {
        let state_clone = state.clone();
        tokio::spawn(async move {
            let event_json = serde_json::json!({
                "specversion": "1.0",
                "type": "com.example.event.type",
                "source": "/api/handler",
                "id": uuid::Uuid::new_v4().to_string(),
                "time": chrono::Utc::now().to_rfc3339_opts(
                    chrono::SecondsFormat::Millis, true
                ),
                "data": { /* event payload */ }
            }).to_string();
            
            // Publish (if fails, just log - don't fail handler)
            if let Err(e) = state_clone.kafka_publisher
                .publish(&event_json).await {
                tracing::error!(error = %e, "Kafka publish failed");
            }
        });
    }
    
    response
}
```

**Why this pattern**?
- ✅ HTTP response returns immediately (no Kafka latency)
- ✅ Publishing fails gracefully (no cascading failures)
- ✅ Error logged for visibility
- ✅ Distributed tracing captures event in span

---

## Configuration: How to Set It?

### At Generation Time (cargo-generate)
```bash
$ cargo generate --path . --name my-service
# Prompts:
# > Enable Kafka event publishing? [y/n] y
# > Kafka broker address: kafka.kafka.svc.cluster.local:9092
# > Kafka topic: events
# > Event name/type: com.mycompany.service.event.published
```

### At Runtime (Environment Variables)
```bash
# Override generation-time values
export APP__KAFKA__BROKER="prod-kafka.example.com:9092"
export APP__KAFKA__TOPIC="production-events"
export APP__KAFKA__EVENT_NAME="com.company.event.published"
```

### Config Files (Development/Staging/Production)
```toml
# config/default.toml
[kafka]
enabled = true
broker = "kafka.kafka.svc.cluster.local:9092"
topic = "events"
event_name = "com.example.service.event.published"

# config/production.toml (overrides)
[kafka]
broker = "prod-kafka.example.com:9092"
```

**Priority**: env vars > {env}.toml > default.toml

---

## Dependencies: What Gets Added?

```toml
[dependencies]
rdkafka = { version = "0.36", optional = true }
cloudevents-sdk = { version = "0.9", features = ["rdkafka"], optional = true }

# Already in use (reuse)
uuid = { version = "1.0", features = ["v4"] }
chrono = { version = "0.4", features = ["serde"] }
serde_json = "1.0"
tracing = "0.1"
tokio = { version = "1", features = ["full"] }

[features]
kafka = ["rdkafka", "cloudevents-sdk"]
```

---

## Testing: How to Verify?

### Unit Test (CloudEvent serialization)
```rust
#[test]
fn test_cloudevent_json() {
    let event = serde_json::json!({
        "specversion": "1.0",
        "type": "com.example.event",
        "source": "/handler",
        "id": "test-id",
        "time": "2025-01-03T15:30:45Z"
    });
    let json = serde_json::to_string(&event).unwrap();
    assert!(json.contains("specversion"));
}
```

### Integration Test (with Kafka)
```bash
# Install testcontainers or use embedded Kafka
cargo test --test kafka_publishing_test -- --ignored
```

### E2E Test (Kind + Kubernetes)
```bash
# Deploy to local Kind cluster
make dev-up
# Send HTTP request
curl http://localhost:8080/api/ping
# Verify event in Kafka topic
kubectl exec -n kafka kafka-0 -- \
  kafka-console-consumer --bootstrap-server localhost:9092 \
  --topic events --from-beginning --max-messages=1
```

---

## Error Handling: What Goes Wrong?

| Scenario | Behavior | Logging |
|----------|----------|---------|
| **Kafka unavailable** | Publish fails silently; handler returns 200 OK | ERROR: "Kafka publish failed: connection refused" |
| **Topic doesn't exist** | Publish fails; logged as error; handler continues | ERROR: "Kafka publish failed: topic not found" |
| **Configuration missing** | Service fails at startup (fail-fast) | FATAL: "Kafka enabled but broker URL missing" |
| **Timestamp format wrong** | CloudEvent validation fails at serialization | ERROR: "Invalid RFC 3339 timestamp" |

**Philosophy**: Kafka publishing is optional (feature-gated); its failure shouldn't cascade.

---

## Observability: How to Monitor?

### Distributed Tracing (OpenTelemetry/Jaeger)
Each publish operation creates a span:
```
HTTP Request (span)
├─ Handler logic (child span)
│  └─ Kafka publish (child span) ← tracks latency, errors
└─ Response
```

### Metrics (Prometheus)
```
kafka_publish_duration_seconds (histogram)
kafka_publish_total (counter)
kafka_publish_errors_total (counter)
```

### Structured Logs (Tracing)
```json
{
  "timestamp": "2025-01-03T15:30:45Z",
  "level": "INFO",
  "message": "Event published to Kafka",
  "event_id": "550e8400...",
  "topic": "events",
  "partition": 0,
  "offset": 12345
}
```

---

## Checklist: Integration Points

### Code Changes
- [ ] `Cargo.toml.liquid`: Add rdkafka, cloudevents-sdk dependencies (conditional)
- [ ] `src/config.rs.liquid`: Add KafkaConfig struct
- [ ] `src/state.rs.liquid`: Add KafkaPublisher to AppState
- [ ] `src/error.rs`: Add KafkaError variant
- [ ] `src/handlers/kafka.rs.liquid`: Publish logic (conditional)
- [ ] `src/observability.rs`: Add Kafka metrics

### Configuration
- [ ] `config/default.toml.liquid`: Add [kafka] section
- [ ] `config/development.toml.liquid`: Dev Kafka address
- [ ] `config/production.toml.liquid`: Prod Kafka address
- [ ] `cargo-generate.toml`: Add prompts for Kafka config

### Deployment
- [ ] `Dockerfile.liquid`: Ensure librdkafka available (Alpine needs apk install)
- [ ] `deploy/base/kustomization.yaml.liquid`: Add kafka-config ConfigMap
- [ ] Update Makefile with `kafka-send-event`, `kafka-list-topics` targets

### Testing
- [ ] `tests/integration/kafka_publishing_test.rs`: Integration tests
- [ ] `tests/e2e/scripts/kafka-test.sh`: E2E test script
- [ ] `tests/common/mod.rs.liquid`: Kafka test helpers

---

## FAQ

**Q: What if Kafka is unavailable?**  
A: HTTP requests still succeed (non-blocking pattern); errors logged at ERROR level for visibility.

**Q: Can I publish to multiple topics?**  
A: This feature is single-topic per service. For multiple topics, deploy multiple services or customize the implementation.

**Q: Do I need to configure Kafka at generation time?**  
A: No, it's optional (feature = "kafka"). Default is disabled; users opt-in during generation.

**Q: How do I track published events?**  
A: Use the `event.id()` field (unique UUID per event) + distributed tracing spans for end-to-end correlation.

**Q: What if the event timestamp is wrong?**  
A: Always use `chrono::Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true)` for RFC 3339 compliance.

**Q: Can I use Protocol Buffers instead of JSON?**  
A: Yes, but it adds complexity. JSON is recommended for this template; Avro is out of scope initially.

---

## Next Steps

1. **Read detailed research**: `CLOUDEVENTS_KAFKA_RESEARCH.md` (all sections)
2. **Review feature spec**: `specs/002-kafka-event-publishing/spec.md`
3. **Check implementation plan**: `specs/002-kafka-event-publishing/plan.md`
4. **Start Phase 1 (Design)**: Create data models, API contracts, quickstart
5. **Generate Phase 2 (Implementation)**: Tasks from `tasks.md`

---

## Quick Links

- **CloudEvents Spec**: https://cloudevents.io/
- **Kafka Protocol Binding**: https://github.com/cloudevents/spec/blob/main/cloudevents/bindings/kafka-protocol-binding.md
- **SDK Rust**: https://github.com/cloudevents/sdk-rust
- **rdkafka Crate**: https://fede1024.github.io/rust-rdkafka/
- **Knative Eventing**: https://knative.dev/docs/eventing/
