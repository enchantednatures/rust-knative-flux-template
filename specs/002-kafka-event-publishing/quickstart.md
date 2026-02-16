# Quickstart: Kafka Event Publishing

**Phase**: 1 (Design & Contracts) | **Date**: 2026-01-03  
**Based on**: `data-model.md` + research findings

This quickstart demonstrates how to enable and use Kafka event publishing in a generated service.

---

## 1. Generate Service with Kafka Publishing

### Step 1: Run cargo-generate

```bash
cargo generate --git https://github.com/your-org/rust-knative-flux-template
```

### Step 2: Answer Prompts

```
Project name: my-awesome-service
S3 storage support? (y/N): n
Enable Kafka event publishing? (y/N): y
Kafka broker URL: kafka.kafka.svc.cluster.local:9092
Kafka topic name: events
CloudEvents type for events: com.mycompany.my-awesome-service.event.published
FluxCD image updates? (y/N): n
Target namespace: default
GitHub organization: mycompany
GitHub repository: my-awesome-service
Default branch: main
```

### Step 3: Verify Generation

Generated files include:

```
my-awesome-service/
├── config/
│   ├── default.toml          # Base configuration (includes Kafka section)
│   ├── development.toml       # Dev overrides (local kafka broker)
│   └── production.toml        # Prod overrides (external kafka cluster)
├── src/
│   ├── config.rs             # KafkaConfig struct (auto-generated)
│   ├── state.rs              # KafkaPublisher in AppState
│   ├── error.rs              # KafkaError variant
│   ├── handlers/
│   │   └── kafka.rs          # Kafka publishing logic (conditional)
│   └── observability.rs       # Kafka metrics
├── Cargo.toml                # Includes rdkafka dependency
└── tests/
    └── integration/
        └── kafka_publishing_test.rs  # Integration tests
```

---

## 2. Configuration

### Default Configuration (generated)

**config/default.toml**:
```toml
[server]
port = 8080

[redis]
url = "redis://127.0.0.1:6379"

[kafka]
broker_url = "kafka.kafka.svc.cluster.local:9092"
topic = "events"
event_name = "com.mycompany.my-awesome-service.event.published"
compression = "snappy"
linger_ms = 5
retries = 3
timeout_ms = 10000
```

### Environment-Specific Overrides

**config/development.toml**:
```toml
[kafka]
broker_url = "kafka.kafka.svc.cluster.local:9092"  # Local Kind cluster
timeout_ms = 5000  # Shorter timeout for dev
```

**config/production.toml**:
```toml
[kafka]
broker_url = "kafka-broker-1.prod:9092,kafka-broker-2.prod:9092,kafka-broker-3.prod:9092"
timeout_ms = 15000  # Longer timeout for prod
```

### Runtime Configuration (Environment Variables)

Override any setting via environment variables (highest priority):

```bash
# Override broker URL
export APP__KAFKA__BROKER_URL="external-kafka:9092"

# Override topic
export APP__KAFKA__TOPIC="prod-events"

# Override event name
export APP__KAFKA__EVENT_NAME="com.newcompany.new-service.event.published"

# Override compression
export APP__KAFKA__COMPRESSION="gzip"

# Override latency settings
export APP__KAFKA__LINGER_MS="10"
export APP__KAFKA__TIMEOUT_MS="20000"

# Run service
cargo run
```

---

## 3. Publishing Events from Handlers

### Publishing in Existing Handlers

When Kafka is enabled, example handlers automatically publish events:

**src/handlers/api.rs** (auto-modified):
```rust
use axum::{
    extract::{Query, State},
    response::IntoResponse,
    Json,
};
use serde_json::{json, Value};
use tracing::instrument;
use crate::state::AppState;

#[instrument(skip(state))]
pub async fn hello(
    State(state): State<Arc<AppState>>,
    Query(params): Query<std::collections::HashMap<String, String>>,
) -> impl IntoResponse {
    let name = params.get("name").map(|s| s.as_str()).unwrap_or("World");
    
    // Create dummy CloudEvent
    let event = crate::handlers::kafka::create_dummy_event(
        &state.config.kafka.as_ref().unwrap().event_name,
        "/api/v1/hello",
    );
    
    // Publish event (non-blocking, spawned in background)
    if let Some(publisher) = &state.kafka_publisher {
        let publisher = publisher.clone();
        let topic = state.config.kafka.as_ref().unwrap().topic.clone();
        
        tokio::spawn(async move {
            if let Err(e) = publisher.publish(&topic, &event).await {
                tracing::error!(error = %e, "Failed to publish event");
            }
        });
    }
    
    Json(json!({
        "message": format!("Hello, {}!", name),
        "event_id": event.id(),
    }))
}
```

### Manual Publishing in Custom Handlers

For custom handlers, publish events explicitly:

```rust
use axum::{extract::State, Json};
use crate::handlers::kafka::create_dummy_event;

pub async fn my_handler(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<MyRequest>,
) -> impl IntoResponse {
    // Do handler logic
    let result = process_request(payload).await;
    
    // Publish event if Kafka enabled
    if let Some(publisher) = &state.kafka_publisher {
        let event = create_dummy_event(
            &state.config.kafka.as_ref().unwrap().event_name,
            "/api/v1/my-endpoint",
        );
        
        let publisher = publisher.clone();
        let topic = state.config.kafka.as_ref().unwrap().topic.clone();
        
        tokio::spawn(async move {
            match publisher.publish(&topic, &event).await {
                Ok((partition, offset)) => {
                    tracing::info!(
                        partition,
                        offset,
                        event_id = %event.id(),
                        "Event published successfully"
                    );
                }
                Err(e) => {
                    tracing::error!(error = %e, "Failed to publish event");
                    // Note: Error does NOT fail the HTTP request
                }
            }
        });
    }
    
    // Return response immediately (publishing happens in background)
    Json(result)
}
```

---

## 4. Development Setup

### Start Local Environment

```bash
# Start Kind cluster with Kafka
make dev-up

# This includes:
# - Kind Kubernetes cluster
# - Knative Serving
# - Kafka broker (in 'kafka' namespace)
# - Redis
# - MinIO (if S3 enabled)
# - PostgreSQL (if postgres enabled)
# - Observability stack (Jaeger, Prometheus)
```

### Run Service Locally

```bash
# Build and run
cargo build
cargo run

# Service listens on http://localhost:8080
```

### Test Event Publishing

```bash
# Make request to handler (auto-publishes event)
curl -X GET "http://localhost:8080/api/v1/hello?name=Alice"

# Expected response:
# {
#   "message": "Hello, Alice!",
#   "event_id": "550e8400-e29b-41d4-a716-446655440000"
# }

# Verify event in Kafka topic
docker exec -it kafka-broker kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic events \
  --from-beginning \
  --max-messages 1
```

### View Distributed Traces

```bash
# Open Jaeger UI
open http://localhost:16686

# Search for traces by:
# - Service: "my-awesome-service"
# - Operation: "hello"
# - Tags: event_id = <uuid from response>

# Traces show:
# - HTTP request span
#   ├── GET /api/v1/hello
#   ├── Duration: 2-5ms (handler)
#   └── Child span: kafka_publish
#       ├── Event ID
#       ├── Topic
#       └── Result (success/failure)
```

---

## 5. Running Tests

### Unit Tests

```bash
# Test CloudEvent generation
cargo test create_dummy_event

# Test configuration loading
cargo test kafka_config

# Run all tests
cargo test
```

### Integration Tests

```bash
# Integration tests use testcontainers for embedded Kafka
# Requires Docker running

# Run integration tests only
cargo test --test '*' -- --ignored

# Run specific integration test
cargo test --test kafka_publishing_test -- --nocapture
```

### E2E Tests

```bash
# Deploy to Kind cluster and test end-to-end
./tests/e2e/scripts/kafka-test.sh

# This script:
# 1. Deploys service to Kind via Kustomize
# 2. Waits for Knative Service to be ready
# 3. Makes HTTP requests
# 4. Verifies events appear in Kafka topic
# 5. Cleans up
```

---

## 6. Production Deployment

### Prerequisites

- External Kafka cluster (3+ brokers recommended)
- TLS certificates if SASL enabled
- Kubernetes secrets for credentials

### Deploy to Production

```bash
# Set environment variables (or use Kubernetes ConfigMap)
export APP__KAFKA__BROKER_URL="kafka-prod-1:9092,kafka-prod-2:9092,kafka-prod-3:9092"
export APP__KAFKA__TOPIC="prod-events"
export APP__KAFKA__EVENT_NAME="com.mycompany.my-awesome-service.event.published"
export APP__KAFKA__TIMEOUT_MS="15000"

# Deploy via FluxCD
git push origin main

# Or manually:
kubectl apply -k deploy/overlays/prod
```

### Monitor Event Publishing

```bash
# View Prometheus metrics
kubectl port-forward -n monitoring svc/prometheus 9090:9090
# Open http://localhost:9090

# Query metrics:
# - kafka_events_published_total
# - kafka_events_failed_total
# - kafka_publish_latency_ms

# View logs (if Loki configured)
# - Search for: job="my-awesome-service" AND "Event published"
# - Search for: job="my-awesome-service" AND "Failed to publish"

# View distributed traces
# - Jaeger UI: http://jaeger.example.com
# - Search by: event_id from response
```

---

## 7. Troubleshooting

### Broker Connection Errors

**Problem**: `BrokerUnreachable`

```
ERROR: Kafka broker unreachable at kafka.kafka.svc.cluster.local:9092: 
    Name or service not known
```

**Solution**:
```bash
# Verify broker is reachable
kubectl get pod -n kafka
kubectl logs -n kafka deployment/kafka

# Update broker URL
export APP__KAFKA__BROKER_URL="correct-broker-url:9092"
```

### Topic Does Not Exist

**Problem**: `TopicNotFound`

```
ERROR: Topic does not exist: my-events
```

**Solution**:
```bash
# Create topic manually
kubectl exec -n kafka kafka-broker-0 -- \
  kafka-topics.sh \
  --create \
  --topic my-events \
  --partitions 3 \
  --replication-factor 1 \
  --bootstrap-server kafka-broker:9092

# Or enable auto-creation in Kafka broker config
auto.create.topics.enable=true
```

### Events Not Appearing

**Problem**: Events publish successfully but don't appear in Kafka

**Solution**:
```bash
# Check metrics
curl http://localhost:8000/metrics | grep kafka_events

# Check logs
kubectl logs deployment/my-awesome-service | grep "Event published"

# Verify topic has messages
kafka-console-consumer \
  --bootstrap-server kafka-broker:9092 \
  --topic events \
  --from-beginning

# Check consumer group lag (if consuming)
kafka-consumer-groups.sh \
  --bootstrap-server kafka-broker:9092 \
  --group my-consumer-group \
  --describe
```

### Performance Issues

**Problem**: Requests are slow

**Potential causes**:
- `linger_ms` too high (waits too long for batching)
- `timeout_ms` too high (waits too long for broker response)
- Network latency to Kafka broker

**Solution**:
```bash
# For low-latency requirements
export APP__KAFKA__LINGER_MS="1"
export APP__KAFKA__TIMEOUT_MS="5000"

# Monitor latency
curl http://localhost:9090/api/v1/query?query=kafka_publish_latency_ms
```

---

## 8. Example: Complete Handler with Error Handling

```rust
use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::sync::Arc;
use tracing::instrument;

use crate::error::AppError;
use crate::handlers::kafka::create_dummy_event;
use crate::state::AppState;

#[derive(Deserialize)]
pub struct HelloParams {
    name: Option<String>,
}

#[derive(Serialize)]
pub struct HelloResponse {
    message: String,
    event_id: String,
}

/// Health check endpoint (no Kafka publishing)
#[instrument]
pub async fn health() -> StatusCode {
    StatusCode::OK
}

/// Example handler with Kafka event publishing
#[instrument(skip(state))]
pub async fn hello(
    State(state): State<Arc<AppState>>,
    Query(params): Query<HelloParams>,
) -> Result<Json<HelloResponse>, AppError> {
    let name = params.name.as_deref().unwrap_or("World");
    
    // Business logic
    let message = format!("Hello, {}!", name);
    
    // Prepare response with event ID for tracing
    let event_id = if let Some(kafka_config) = &state.config.kafka {
        let event = create_dummy_event(
            &kafka_config.event_name,
            "/api/v1/hello",
        );
        let event_id_clone = event.id().to_string();
        
        // Publish event asynchronously (non-blocking)
        if let Some(publisher) = &state.kafka_publisher {
            let publisher = publisher.clone();
            let topic = kafka_config.topic.clone();
            
            tokio::spawn(async move {
                match publisher.publish(&topic, &event).await {
                    Ok((partition, offset)) => {
                        tracing::info!(
                            partition,
                            offset,
                            event_id = %event_id_clone,
                            "Event published to Kafka"
                        );
                    }
                    Err(e) => {
                        tracing::error!(
                            error = %e,
                            event_id = %event_id_clone,
                            "Failed to publish event to Kafka (continuing with HTTP response)"
                        );
                        // Note: Error does NOT affect HTTP response
                    }
                }
            });
        }
        
        event_id_clone
    } else {
        "kafka-disabled".to_string()
    };
    
    Ok(Json(HelloResponse {
        message,
        event_id,
    }))
}
```

---

## Next Steps

1. **Customize Event Payload**: Modify `create_dummy_event()` to include business-specific data
2. **Add Consumer**: Create a separate service to consume published events from Kafka
3. **Schema Validation**: Integrate with Confluent Schema Registry (optional)
4. **Advanced Patterns**:
   - Event deduplication using event.id()
   - Event filtering by type
   - Multiple topics (create separate service instances)
5. **Monitor**: Set up alerts on `kafka_events_failed_total` metric

---

## References

- **CloudEvents 1.0 Spec**: https://github.com/cloudevents/spec/blob/v1.0.2/cloudevents/spec.md
- **Kafka Protocol**: https://kafka.apache.org/documentation/
- **rdkafka Rust Client**: https://github.com/fede1024/rust-rdkafka
- **OpenTelemetry**: https://opentelemetry.io/
- **Knative Eventing**: https://knative.dev/docs/eventing/
