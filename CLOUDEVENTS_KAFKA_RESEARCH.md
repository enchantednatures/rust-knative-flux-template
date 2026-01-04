# Research: CloudEvents + Kafka Integration for Rust

**Date**: 2026-01-03  
**Context**: Supporting Kafka event publishing feature (spec: `002-kafka-event-publishing`)  
**Scope**: Publishing dummy CloudEvents to Kafka topics from HTTP handlers in Rust

---

## 1. CloudEvents Standard Compliance (v1.0)

### Required Fields

All CloudEvents 1.0 messages must include these fields:

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `specversion` | String | CloudEvents specification version | `"1.0"` |
| `type` | String | Event type in reverse-domain notation | `"com.example.service.event.published"` |
| `source` | URI-reference | Event origin/producer | `"https://example.com/api/handlers/ping"` |
| `id` | String | Unique event identifier | `"550e8400-e29b-41d4-a716-446655440000"` |
| `time` | Timestamp (optional but recommended) | ISO 8601 UTC timestamp | `"2025-01-03T15:30:45.123Z"` |

### Optional Fields (Commonly Used)

| Field | Type | Purpose |
|-------|------|---------|
| `datacontenttype` | String | Media type of `data` field | `"application/json"` |
| `dataschema` | URI | Schema of `data` field | `"https://example.com/schemas/event-v1.json"` |
| `subject` | String | Context-specific subject | `"user/12345"` |
| `data` | Any | Event payload/message body | JSON object |

**Additional optional fields for distributed tracing:**
- `traceparent` (per W3C Trace Context spec)
- `tracestate` (W3C Trace Context state)
- Custom attributes (e.g., `b3` for B3 single header propagation)

### Serialization Formats

#### **JSON Format** (Structured Encoding)
- **Use case**: HTTP POST bodies, Kafka message values (structured mode)
- **Content-Type**: `application/cloudevents+json`
- **Advantages**: Human-readable, standard JSON tooling, nested data support
- **Example**:
```json
{
  "specversion": "1.0",
  "type": "com.example.service.event.published",
  "source": "/api/handlers/ping",
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "time": "2025-01-03T15:30:45.123Z",
  "datacontenttype": "application/json",
  "data": {
    "message": "hello world",
    "timestamp": "2025-01-03T15:30:44Z"
  }
}
```

#### **Protocol Buffer Format** (Avro)
- **Use case**: Binary serialization for bandwidth/performance optimization
- **Advantages**: Compact, fast serialization, schema evolution support
- **Status**: Official spec support (v1.0.2+)
- **When to use**: High-throughput scenarios (>10k events/sec)
- **Not recommended** for this template: Adds complexity; JSON sufficient for Knative workloads

#### **Binary Encoding (HTTP Protocol Binding)**
- **Use case**: HTTP headers contain metadata, body contains raw data
- **Content-Type of body**: Specified in `datacontenttype` header
- **Kafka mapping**: Can use binary mode with `ce-*` headers in Kafka message headers
- **Headers example**:
  ```
  ce-specversion: 1.0
  ce-type: com.example.service.event.published
  ce-source: /api/handlers/ping
  ce-id: 550e8400-e29b-41d4-a716-446655440000
  ce-time: 2025-01-03T15:30:45.123Z
  content-type: application/json
  ```

### Recommendation for This Template
- **Primary**: JSON structured encoding (simplest, most compatible)
- **Secondary**: Binary encoding for advanced use cases (optional)
- **Not needed**: Protocol Buffers/Avro (add unnecessary complexity)

---

## 2. Existing Rust CloudEvents Crates

### Official: `cloudevents-sdk` (v0.9.0)

**Repository**: https://github.com/cloudevents/sdk-rust  
**Crate**: https://crates.io/crates/cloudevents-sdk

#### Capabilities
- ✅ Full CloudEvents 1.0 spec support (core + bindings)
- ✅ Multiple protocol bindings: HTTP, Kafka (rdkafka), NATS, Actix, Axum, Warp, Reqwest
- ✅ JSON serialization/deserialization
- ✅ EventBuilder pattern for type-safe event construction
- ✅ Integration examples for rdkafka, actix, axum
- ✅ Actively maintained by CNCF
- ✅ Apache 2.0 licensed

#### API Example
```rust
use cloudevents::{EventBuilder, EventBuilderV10};
use url::Url;
use std::str::FromStr;

// Create event using builder pattern
let event = EventBuilderV10::new()
    .id("550e8400-e29b-41d4-a716-446655440000")
    .source(Url::from_str("https://example.com/api/handlers/ping")?)
    .ty("com.example.service.event.published")
    .data("application/json", r#"{"message":"hello"}"#)
    .build()?;

// Serialize to JSON
let json = serde_json::to_string(&event)?;
```

#### Pros
- Official CNCF project with long-term support
- Type-safe EventBuilder pattern
- Excellent Kafka integration via feature flags
- Well-documented examples
- Battle-tested in production (used by major cloud providers)

#### Cons
- Requires adding new dependency (already using axum, so compatible)
- Steeper learning curve than vendored library
- Less customization than custom implementation

#### Kafka Support
- **Feature flag**: `rdkafka`
- **Integration**: Direct support for publishing events via rdkafka producer
- **Example**: See `/example-projects/rdkafka-example` in sdk-rust repo
- **Pattern**: `event.to_kafka_message()` converts to Kafka protocol binding format

#### Verdict: **RECOMMENDED for publishing** (if adding external dependency acceptable)

---

### Vendored: `axum-cloudevents` (This Template)

**Location**: `crates/axum-cloudevents/`  
**Version**: 0.1.0 (local)  
**Status**: Custom, maintained within this template

#### Current Capabilities
- ✅ CloudEvents 1.0 spec parsing (core fields)
- ✅ Structured JSON mode (from request body)
- ✅ Binary mode (from ce-* headers)
- ✅ Type-safe extraction in Axum handlers via `CloudEvent<T>` extractor
- ✅ Metadata access: `event.id()`, `event.r#type()`, `event.source()`, etc.
- ✅ Deserializes typed data payloads

#### Current Limitations
- ❌ **No serialization**: Cannot create/publish events (extraction only)
- ❌ **No Kafka support**: No protocol binding for Kafka publishing
- ❌ **No EventBuilder**: Cannot construct events programmatically
- ❌ **Limited optional fields**: Minimal extension support

#### How to Extend for Publishing

To add publishing capability to vendored `axum-cloudevents`:

1. **Add serialization method** (`crates/axum-cloudevents/src/extractor.rs`):
   ```rust
   impl<T: Serialize> CloudEvent<T> {
       /// Serialize to JSON (structured encoding)
       pub fn to_json(&self) -> Result<String, serde_json::Error> {
           // Combine metadata + data into single JSON object
           serde_json::to_string(&serde_json::json!({
               "specversion": self.metadata.spec_version,
               "type": self.metadata.r#type,
               "source": self.metadata.source,
               "id": self.metadata.id,
               "time": self.metadata.time,
               "datacontenttype": self.metadata.data_content_type,
               "data": serde_json::to_value(&self.data)?
           }))
       }
   }
   ```

2. **Add CloudEvent builder** (new file: `crates/axum-cloudevents/src/builder.rs`):
   ```rust
   #[derive(Debug)]
   pub struct CloudEventBuilder<T> {
       metadata: CloudEventMetadata,
       data: Option<T>,
   }

   impl<T: Default> CloudEventBuilder<T> {
       pub fn new(id: String, source: String, ty: String) -> Self {
           Self {
               metadata: CloudEventMetadata::new(id, source, ty),
               data: Some(T::default()),
           }
       }
       
       pub fn with_data(mut self, data: T) -> Self {
           self.data = Some(data);
           self
       }
       
       pub fn build(self) -> Result<CloudEvent<T>, CloudEventError> {
           Ok(CloudEvent {
               metadata: self.metadata,
               data: self.data.ok_or(CloudEventError::MissingField("data"))?,
           })
       }
   }
   ```

#### Verdict: **POSSIBLE but COMPLEX** (requires significant custom work for full feature parity)

---

### Comparison: `cloudevents-sdk` vs `axum-cloudevents` (vendored)

| Aspect | `cloudevents-sdk` | `axum-cloudevents` |
|--------|-------|-------|
| **Serialization** | ✅ Full support | ❌ Not implemented |
| **Builder pattern** | ✅ EventBuilder | ❌ Would need to add |
| **Kafka integration** | ✅ Native (rdkafka feature) | ❌ Would need to add |
| **HTTP/Protocol binding** | ✅ Comprehensive | ⚠️ Basic HTTP only |
| **Extension attributes** | ✅ Yes | ⚠️ Limited |
| **Type safety** | ✅ Excellent | ✅ Good (Axum integration better) |
| **Production readiness** | ✅ Mature | ⚠️ Experimental (this template) |
| **Maintenance burden** | ✅ CNCF maintained | ❌ Self-maintained |
| **Code size** | 📦 ~15KB | 📦 ~5KB |
| **Customization** | ⚠️ Limited | ✅ Full control |

**Recommendation**: Use `cloudevents-sdk` with `rdkafka` feature for publishing; extend `axum-cloudevents` for consumption consistency.

---

## 3. Kafka Message Format Conventions

### CloudEvents Protocol Binding for Kafka (Spec)

**Official Spec**: https://github.com/cloudevents/spec/blob/main/cloudevents/bindings/kafka-protocol-binding.md

#### Content Type Header

When publishing CloudEvents to Kafka:

```
Content-Type: application/cloudevents+json; charset=utf-8
```

This header is **NOT** stored in Kafka message headers; it's used by consumers to identify the format.

#### Two Encoding Modes in Kafka

##### Mode 1: **Structured Content Mode** (Recommended)
- **Description**: Entire CloudEvent (metadata + data) in Kafka message value as JSON
- **Kafka Message Format**:
  ```
  Topic: events
  Key: null (or event.id() for deterministic partitioning)
  Headers: Content-Type: application/cloudevents+json
  Value: {
    "specversion": "1.0",
    "type": "com.example.service.event.published",
    "source": "/api/handlers/ping",
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "time": "2025-01-03T15:30:45.123Z",
    "data": { ... }
  }
  ```
- **Advantages**: Single message value, easy serialization, standard JSON tools
- **Disadvantages**: Data not directly queryable without deserializing entire value
- **Best for**: Most Knative/serverless workloads

##### Mode 2: **Binary Content Mode** (Advanced)
- **Description**: CloudEvent metadata in Kafka headers, data in message value
- **Kafka Message Format**:
  ```
  Topic: events
  Key: null
  Headers:
    ce-specversion: 1.0
    ce-type: com.example.service.event.published
    ce-source: /api/handlers/ping
    ce-id: 550e8400-e29b-41d4-a716-446655440000
    ce-time: 2025-01-03T15:30:45.123Z
    content-type: application/json
  Value: { ... data payload only ... }
  ```
- **Advantages**: Metadata available without deserializing value; better for filtering
- **Disadvantages**: More headers overhead; consumers must parse multiple headers
- **Best for**: High-volume scenarios with header-based filtering

**For this template**: Use **Structured Content Mode** (simpler, more portable).

### Topic Naming Conventions

**CloudEvents-Kafka best practices** (not strict rules):

1. **Reverse-domain notation** (preferred):
   - ✅ `com.example.service.events`
   - ✅ `org.company.user.service.events`

2. **Hierarchical naming** (for Kafka topic organization):
   - ✅ `events-user-created`
   - ✅ `events-order-placed`
   - ✅ `events-payment-processed`

3. **Flat naming** (simple, widely used):
   - ✅ `events` (single topic, event type in CloudEvent `type` field)
   - ✅ `user-events`

4. **What to avoid**:
   - ❌ `user_created_event` (underscores inconsistent with event type naming)
   - ❌ `Event-Topic` (mixed case hard to remember)
   - ❌ UPPERCASE (not idiomatic for Kafka)

**Recommendation for this template**:
- Use a single configurable topic name (e.g., `events`)
- Route by CloudEvent `type` field (already supported in existing KAFKA_EVENTING.md)
- Event type format: `com.example.service.event.published` (matches reverse-domain convention)

### Partition Key Strategy

**Key decisions**:

| Scenario | Key | Benefit |
|----------|-----|---------|
| **Event ID** | `event.id()` | Deterministic placement; enables deduplication |
| **User/Entity ID** | e.g., `user_id` from data | Ordered events per user |
| **Null/Round-robin** | `null` | Balanced across partitions (default Kafka behavior) |
| **Source** | `event.source()` | Events from same source stay together |

**Best practice**: Use `event.id()` as partition key for:
- ✅ Idempotent processing (duplicate detection per partition)
- ✅ Deterministic ordering within event ID scope
- ✅ No data leakage (IDs are usually UUIDs, not sensitive)

**Code example**:
```rust
let partition_key = event.id().to_bytes();
let record = FutureRecord::to("events")
    .key(&partition_key)
    .payload(event_json.as_bytes());
```

---

## 4. Integration with Existing Template Patterns

### Current CloudEvents Handling (Consumption)

**File**: `src/handlers/events.rs`

The template **consumes** CloudEvents via `axum-cloudevents`:

```rust
pub async fn handle_event(event: CloudEvent<Ping>) -> Json<Pong> {
    // CloudEvent extracted automatically from request
    let id = event.id();
    let event_type = event.r#type();
    let source = event.source();
    let data = &event.data; // Typed payload
    
    // Process event...
}
```

**Key patterns**:
- ✅ CloudEvent extractor handles HTTP binary + structured modes
- ✅ Typed data payload via generic `T`
- ✅ Instrumented with `#[instrument]` macro for tracing
- ✅ Structured logging via `tracing` crate
- ✅ Error handling via AppError + IntoResponse

### Publishing Pattern (Proposed)

To maintain consistency, publishing should follow:

1. **Module organization**: New `handlers/kafka.rs` (if Kafka enabled)
2. **Configuration**: `KafkaConfig` in `config.rs` (similar to Redis config)
3. **State integration**: `KafkaPublisher` in `AppState` (like Redis client)
4. **Error handling**: `KafkaError` variant in `AppError`
5. **Instrumentation**: `#[instrument]` on all publish functions
6. **Async pattern**: `tokio::spawn` for non-blocking publishing

**Proposed publishing handler**:

```rust
// File: src/handlers/kafka.rs (conditional)

use crate::state::AppState;
use axum_cloudevents::CloudEvent;
use serde::{Deserialize, Serialize};
use tracing::instrument;

#[derive(Debug, Serialize)]
pub struct DummyEvent {
    pub message: String,
    pub timestamp: String,
}

#[instrument(skip(state), fields(event_id = %event.id()))]
pub async fn publish_dummy_event(
    state: State<AppState>,
    event: CloudEvent<DummyEvent>,
) -> Result<Json<PublishResponse>, AppError> {
    // Spawn async task to publish (non-blocking)
    let state_clone = state.clone();
    let event_json = event.to_json()?;
    
    tokio::spawn(async move {
        if let Err(e) = state_clone.kafka_publisher.publish(
            &event.id(),
            &event_json
        ).await {
            tracing::error!(
                error = %e,
                event_id = %event.id(),
                "Failed to publish event to Kafka"
            );
        }
    });
    
    Ok(Json(PublishResponse { 
        success: true, 
        event_id: event.id().to_string() 
    }))
}
```

### Distributed Tracing Integration

**Existing setup** (from `src/observability.rs`):
- ✅ OpenTelemetry OTLP exporter
- ✅ B3 header propagation (critical for Knative)
- ✅ Tracing subscriber with JSON output
- ✅ Request ID correlation via tower-http

**Publishing integration**:

```rust
// Ensure B3 headers propagated to Kafka
#[instrument(err)]
async fn publish_to_kafka(
    publisher: &KafkaPublisher,
    event: &CloudEvent<T>,
) -> Result<(), AppError> {
    let span = tracing::Span::current();
    
    // Extract trace context from current span
    let trace_id = span.span().trace_id(); // From OpenTelemetry
    
    // Include trace context in CloudEvent (optional, for correlation)
    // Many systems also look at B3 headers if available
    
    publisher.publish(event.id(), &event_json).await?;
    Ok(())
}
```

**Key pattern**: Each publish operation creates a child span of the HTTP request, enabling end-to-end tracing from handler → Kafka → consumer.

---

## 5. Dummy Event Generation Best Practices

### Minimal Payload Structure

**Example dummy event** (following template patterns):

```rust
#[derive(Debug, Serialize, Deserialize)]
pub struct DummyEventData {
    /// Simple test message
    pub message: String,
    /// Handler path that triggered the event
    pub handler_path: String,
    /// When the event was generated
    pub generated_at: String,
}
```

**Generated event**:
```json
{
  "specversion": "1.0",
  "type": "com.example.service.event.handler.invoked",
  "source": "/api/handlers/ping",
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "time": "2025-01-03T15:30:45.123Z",
  "datacontenttype": "application/json",
  "data": {
    "message": "Handler invoked",
    "handler_path": "/api/handlers/ping",
    "generated_at": "2025-01-03T15:30:45.123Z"
  }
}
```

### Timestamp Formatting (ISO 8601)

**CloudEvents spec requirement**: RFC 3339 (subset of ISO 8601)

**Format**: `YYYY-MM-DDTHH:MM:SS.sssZ` (UTC/Zulu time)

**Implementation**:
```rust
use chrono::Utc;

// Get current time in RFC 3339 format
let now = Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
// Result: "2025-01-03T15:30:45.123Z"
```

**Note**: The template already uses `chrono` (see `Cargo.toml.liquid`), so this is free.

### Event Naming Conventions

**CloudEvent `type` field** (per CloudEvents spec):

1. **Reverse-domain notation** (RECOMMENDED):
   - ✅ `com.example.service.event.handler.invoked`
   - ✅ `org.company.platform.kafka.event.published`
   - Pattern: `domain.service.entity.action`

2. **Prefix pattern** (alternative):
   - ✅ `service.event.published`
   - ✅ `user.created`
   - Pattern: `subject.entity.action`

3. **What to avoid**:
   - ❌ `event-published` (hyphens conflict with domain notation)
   - ❌ `EventPublished` (uppercase inconsistent with spec examples)
   - ❌ `publish` (too generic; lacks context)

**For this template** (from spec requirements):
- Configurable at generation time (e.g., `com.example.service.event.published`)
- Stored in `KafkaConfig::event_name`
- Used in every CloudEvent published

**Generation-time config**:
```toml
# config/default.toml.liquid
[kafka]
event_name = "{{ kafka_event_name }}"  # e.g., "com.example.service.event.published"
```

---

## 6. Recommended Crate Choices & Implementation Strategy

### Kafka Client Library Decision

**Candidates**:

1. **`rdkafka`** (Recommended)
   - **Stars**: ⭐⭐⭐⭐⭐ (1.5K+ on GitHub)
   - **Maturity**: Production-ready (used by Confluent, Shopify)
   - **License**: MIT/Apache 2.0
   - **Pros**:
     - ✅ Official Kafka C library binding (librdkafka)
     - ✅ Excellent performance (C performance with Rust safety)
     - ✅ Full protocol support (transactions, idempotence, etc.)
     - ✅ Connection pooling built-in
     - ✅ Featured in `cloudevents-sdk` integration examples
   - **Cons**:
     - ⚠️ Requires librdkafka C library (install: `librdkafka-dev`)
     - ⚠️ Docker/musl builds need special handling
   - **Version**: `0.36.0+` (current stable)

2. **`tokio-kafka`** (Pure Rust, emerging)
   - **Maturity**: Experimental/developing
   - **Pros**:
     - ✅ Pure Rust (no C dependencies)
     - ✅ Async-native design
   - **Cons**:
     - ❌ Not production-ready (missing features)
     - ❌ Limited community adoption
     - ❌ Incomplete feature set
   - **Verdict**: Not suitable for this template yet

3. **`kafka-protocol`** (Low-level)
   - **Use case**: Custom protocol handling
   - **Verdict**: Too low-level; overkill for simple publishing

**DECISION**: Use **`rdkafka`** with `cloudevents-sdk` for optimal integration.

### Dependency Stack

```toml
# Kafka publishing (conditional feature)
[dependencies]
rdkafka = { version = "0.36", optional = true }
cloudevents-sdk = { version = "0.9", features = ["rdkafka"], optional = true }

# Already in use (reuse for CloudEvents building)
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
uuid = { version = "1.0", features = ["v4", "serde"] }
chrono = { version = "0.4", features = ["serde"] }
tracing = "0.1"
tokio = { version = "1", features = ["full"] }

[features]
kafka = ["rdkafka", "cloudevents-sdk"]
```

### Code Structure (Template with Kafka)

**When feature enabled (`features=["kafka"]`)**:

```
src/
├── config.rs.liquid
│   └── struct KafkaConfig {
│       pub broker: String,
│       pub topic: String,
│       pub event_name: String,
│   }
├── state.rs.liquid
│   └── struct AppState {
│       pub redis: MultiplexedConnection,
│       #[cfg(feature = "kafka")]
│       pub kafka_publisher: KafkaPublisher,
│   }
├── error.rs
│   └── enum AppError {
│       #[cfg(feature = "kafka")]
│       #[error("Kafka publish error: {0}")]
│       KafkaPublish(String),
│   }
├── observability.rs
│   └── // Add kafka publishing metrics
├── handlers/
│   ├── mod.rs
│   │   └── #[cfg(feature = "kafka")] pub mod kafka_publish;
│   └── kafka_publish.rs.liquid (conditional)
│       └── pub async fn publish_dummy_event(...)
└── lib.rs.liquid
    └── #[cfg(feature = "kafka")] pub use handlers::kafka_publish;
```

### Kafka Publisher Abstraction

```rust
// File: src/handlers/kafka_publisher.rs (or similar)

pub struct KafkaPublisher {
    producer: FutureProducer,
    topic: String,
}

impl KafkaPublisher {
    pub async fn new(config: &KafkaConfig) -> Result<Self, AppError> {
        let producer_config = ClientConfig::new()
            .set("bootstrap.servers", &config.broker)
            .set("client.id", "knative-service")
            .create::<FutureProducer>()?;
        
        Ok(Self {
            producer: producer_config,
            topic: config.topic.clone(),
        })
    }
    
    #[instrument(skip(self), fields(topic = %self.topic, event_id = %event_id))]
    pub async fn publish(
        &self,
        event_id: &str,
        json_event: &str,
    ) -> Result<(), AppError> {
        let record = FutureRecord::to(&self.topic)
            .key(event_id) // Use event ID as partition key
            .payload(json_event);
        
        match self.producer.send(record, Duration::from_secs(30)).await {
            Ok((partition, offset)) => {
                tracing::info!(
                    partition = partition,
                    offset = offset,
                    "Event published to Kafka"
                );
                Ok(())
            }
            Err((err, _)) => {
                tracing::error!(error = %err, "Failed to publish to Kafka");
                Err(AppError::KafkaPublish(err.to_string()))
            }
        }
    }
}
```

---

## 7. Recommended Publishing Pattern

### Handler Integration

```rust
// Minimal example: Publish dummy event on handler invocation

use axum::{extract::State, Json};
use crate::state::AppState;

#[instrument]
pub async fn ping_handler(
    State(state): State<AppState>,
) -> Json<PingResponse> {
    // 1. Prepare response
    let response = PingResponse { 
        message: "pong".to_string() 
    };
    
    // 2. Spawn async task to publish event (non-blocking)
    #[cfg(feature = "kafka")]
    {
        let state_clone = state.clone();
        tokio::spawn(async move {
            let event_json = serde_json::json!({
                "specversion": "1.0",
                "type": "com.example.service.handler.invoked",
                "source": "/api/ping",
                "id": uuid::Uuid::new_v4().to_string(),
                "time": chrono::Utc::now().to_rfc3339_opts(
                    chrono::SecondsFormat::Millis, 
                    true
                ),
                "data": {
                    "handler": "ping",
                    "success": true,
                }
            }).to_string();
            
            if let Err(e) = state_clone.kafka_publisher
                .publish(&event_json).await {
                tracing::error!(error = %e, "Failed to publish event");
            }
        });
    }
    
    // 3. Return response immediately (non-blocking)
    Json(response)
}
```

### Error Handling Strategy

```rust
// Graceful degradation: Publishing failure ≠ request failure

// ✅ GOOD: Publish fails, request still succeeds
pub async fn handler(State(state): State<AppState>) -> Json<Response> {
    tokio::spawn(async move {
        // Publishing happens in background
        // If fails, only logs error; doesn't affect handler
        if let Err(e) = state.kafka.publish(&event).await {
            tracing::error!("publish failed: {}", e);
        }
    });
    Json(Response { success: true }) // ← Always returns 200
}

// ❌ BAD: Publishing failure cascades to request failure
pub async fn handler(State(state): State<AppState>) -> Result<Json<Response>, AppError> {
    state.kafka.publish(&event).await?; // ← Causes handler to fail
    Ok(Json(Response { success: true }))
}
```

---

## 8. Configuration Hierarchy

Following existing template patterns (`figment` + `TOML`):

```toml
# config/default.toml.liquid
[kafka]
enabled = false
broker = "localhost:9092"
topic = "events"
event_name = "service.event.published"
```

```toml
# config/development.toml.liquid (override)
[kafka]
broker = "kafka.kafka.svc.cluster.local:9092"
```

```bash
# Runtime override (highest priority)
export APP__KAFKA__BROKER="external-kafka.prod.example.com:9092"
export APP__KAFKA__ENABLED="true"
```

**Loading order**:
1. `default.toml` (defaults)
2. `{ENV}.toml` (dev/staging/prod overrides)
3. `APP__KAFKA__*` env vars (runtime overrides)

---

## 9. Testing Strategy

### Unit Tests

```rust
#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_kafka_config_from_env() {
        // Test configuration loading from environment
    }
    
    #[test]
    fn test_cloudevent_json_serialization() {
        // Test CloudEvent → JSON serialization
        let event = create_test_event();
        let json = event.to_json().unwrap();
        assert!(json.contains("\"specversion\":\"1.0\""));
    }
    
    #[tokio::test]
    async fn test_kafka_publisher_creation() {
        // Test KafkaPublisher initialization
    }
}
```

### Integration Tests (Testcontainers)

```rust
// tests/integration/kafka_publishing_test.rs

#[tokio::test]
#[ignore] // Run with `cargo test -- --ignored`
async fn test_publish_to_kafka() {
    // Start embedded Kafka via testcontainers
    let kafka = testcontainers::clients::Cli::default()
        .run(testcontainers::images::kafka::Kafka::default());
    
    // Publish event
    // Verify event appears in topic
}
```

### E2E Tests (Kind + Kubernetes)

```bash
# tests/e2e/scripts/kafka-test.sh
# 1. Deploy service to Kind
# 2. Send HTTP request to handler
# 3. Verify event in Kafka topic
# 4. Check distributed tracing in Jaeger
```

---

## 10. Summary & Recommendations

### Implementation Checklist

- [ ] **Dependency Choice**: Use `cloudevents-sdk` (v0.9+) + `rdkafka` (v0.36+)
- [ ] **Serialization**: JSON structured encoding (most compatible with Kafka)
- [ ] **Publishing Mode**: Asynchronous (spawn task to avoid blocking HTTP)
- [ ] **Error Handling**: Graceful degradation (publish failures don't fail requests)
- [ ] **Configuration**: Three-tier hierarchy (defaults + env + env vars)
- [ ] **Instrumentation**: `#[instrument]` on all publish functions
- [ ] **Testing**: Unit + integration (testcontainers) + E2E (Kind)
- [ ] **Tracing**: Include trace context in published events
- [ ] **Topic Strategy**: Single configurable topic; route by CloudEvent `type`
- [ ] **Partition Key**: Use `event.id()` for deterministic placement

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Kafka Client** | `rdkafka` | Production-ready, excellent performance, CNCF integration |
| **CloudEvents Lib** | `cloudevents-sdk` | Official CNCF, active maintenance, Kafka support |
| **Encoding** | JSON structured | Most portable, human-readable, standard tools |
| **Publishing** | Async (spawn task) | Non-blocking, prevent handler latency impact |
| **Error Handling** | Graceful degradation | Publishing failures don't fail requests |
| **Config** | Figment 3-tier | Consistent with existing template patterns |
| **Timestamps** | ISO 8601 (RFC 3339) | CloudEvents spec requirement |
| **Partition Key** | Event ID | Deterministic, enables deduplication |

### Template Integration Points

1. **`Cargo.toml.liquid`**: Add `rdkafka`, `cloudevents-sdk` as optional dependencies
2. **`src/config.rs.liquid`**: Add `KafkaConfig` struct
3. **`src/state.rs.liquid`**: Add `KafkaPublisher` to `AppState` (conditional)
4. **`src/error.rs`**: Add `KafkaError` enum variant
5. **`src/observability.rs`**: Add Kafka publishing metrics
6. **`src/handlers/`**: Add `kafka.rs.liquid` (conditional) with publishing logic
7. **`config/*.toml.liquid`**: Add `[kafka]` section (conditional)
8. **`tests/integration/`**: Add `kafka_publishing_test.rs` (conditional)
9. **`Dockerfile.liquid`**: Ensure rdkafka C libraries available (Alpine needs special handling)
10. **`deploy/base/kustomization.yaml.liquid`**: Add `kafka-config.yaml` ConfigMap (conditional)

---

## References

- **CloudEvents Spec**: https://cloudevents.io/
- **Kafka Protocol Binding**: https://github.com/cloudevents/spec/blob/main/cloudevents/bindings/kafka-protocol-binding.md
- **Official SDK-Rust**: https://github.com/cloudevents/sdk-rust
- **rdkafka**: https://fede1024.github.io/rust-rdkafka/
- **Knative Eventing**: https://knative.dev/docs/eventing/
- **Existing Template Docs**: `docs/KAFKA_EVENTING.md`, `docs/KNATIVE_EVENTING.md`
