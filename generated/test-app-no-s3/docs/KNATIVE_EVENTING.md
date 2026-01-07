# Knative Eventing Guide

This document explains how to emit CloudEvents to your Knative service and how Knative routes them to your application.

## Overview

Your service is configured to receive [CloudEvents](https://cloudevents.io/) - a standardized format for describing events in distributed systems. Knative Eventing provides event routing, filtering, and delivery guarantees.

## Quick Start: Send an Event

### Using curl (local development)

First, start port forwarding to your service:

```bash
# In terminal 1
make dev-forward

# In terminal 2
curl -X POST http://localhost:8080/ \
  -H "ce-specversion: 1.0" \
  -H "ce-type: com.example.ping" \
  -H "ce-source: /local/test" \
  -H "ce-id: test-event-123" \
  -H "Content-Type: application/json" \
  -d '{"message": "Hello from CloudEvent!"}'
```

**Expected response:**
```json
{
  "reply": "pong: Hello from CloudEvent!",
  "event_id": "test-event-123"
}
```

### CloudEvent Headers Explained

| Header | Required | Example | Description |
|--------|----------|---------|-------------|
| `ce-specversion` | ✅ Yes | `1.0` | CloudEvents specification version |
| `ce-type` | ✅ Yes | `com.example.ping` | Event type (namespace.action format) |
| `ce-source` | ✅ Yes | `/my-app/component` | Event source/origin |
| `ce-id` | ✅ Yes | `event-uuid` | Unique event identifier |
| `ce-time` | ❌ Optional | `2025-12-25T12:00:00Z` | Event timestamp (RFC3339) |
| `ce-datacontenttype` | ❌ Optional | `application/json` | Content type of body |
| `ce-subject` | ❌ Optional | `/resource/id` | Describes subject of the event |

## Event Handler Implementation

Your service has a built-in event handler in `src/handlers/events.rs`:

```rust
pub async fn handle_event(event: CloudEvent<Ping>) -> Json<Pong> {
    tracing::info!(
        event_id = %event.id(),
        event_type = %event.r#type(),
        source = %event.source(),
        message = %event.data.message,
        "Received CloudEvent",
    );

    Json(Pong {
        reply: format!("pong: {}", event.data.message),
        event_id: event.id().to_string(),
    })
}
```

The handler:
- Accepts CloudEvents with a `Ping` data payload
- Logs all event metadata
- Responds with a `Pong` containing the reply and event ID

## Production: Emit Events from Knative Eventing

### Architecture

```
Event Source → Broker → Trigger → Your Service
```

- **Event Source**: Creates events (Kafka, webhook, timer, etc.)
- **Broker**: Central event routing component
- **Trigger**: Routes events from broker to services based on filters
- **Your Service**: Receives and processes CloudEvents

### Example: Create an Event Broker

```yaml
apiVersion: eventing.knative.dev/v1
kind: Broker
metadata:
  name: default
  namespace: default
spec:
  # Delivery policy for failed events
  delivery:
    deadLetterSink:
      ref:
        apiVersion: serving.knative.dev/v1
        kind: Service
        name: dead-letter-service
    retryPolicy: exponential
    backoffPolicy: exponential
    backoffDelay: PT1S
    backoffDuration: PT300S
```

### Example: Create a Trigger

```yaml
apiVersion: eventing.knative.dev/v1
kind: Trigger
metadata:
  name: ping-trigger
  namespace: default
spec:
  broker: default
  subscriber:
    ref:
      apiVersion: serving.knative.dev/v1
      kind: Service
      name: rust-service  # Your service name
  filter:
    attributes:
      type: com.example.ping
      source: /my-app/*
```

This trigger will route all events with:
- `type: com.example.ping`
- `source` matching `/my-app/*` pattern

to your Knative service.

### Example: Create a Webhook Event Source

```yaml
apiVersion: sources.knative.dev/v1
kind: SinkBinding
metadata:
  name: webhook-event-source
  namespace: default
spec:
  subject:
    apiVersion: v1
    kind: Pod
    selector:
      matchLabels:
        app: webhook-receiver
  sink:
    ref:
      apiVersion: eventing.knative.dev/v1
      kind: Broker
      name: default
```

## Advanced: Custom Event Types

### Define Your Event Type

Update `src/handlers/events.rs` to support custom events:

```rust
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
pub struct OrderCreated {
    pub order_id: String,
    pub customer_id: String,
    pub amount: f64,
}

#[derive(Debug, Deserialize)]
pub struct UserSignup {
    pub user_id: String,
    pub email: String,
}

pub enum EventPayload {
    OrderCreated(OrderCreated),
    UserSignup(UserSignup),
    Ping(Ping),
}
```

### Create Type-Specific Handlers

```rust
pub async fn handle_order_created(
    event: CloudEvent<OrderCreated>
) -> Result<Json<OrderResponse>, AppError> {
    let data = event.data;
    tracing::info!(
        order_id = %data.order_id,
        amount = data.amount,
        "Processing order"
    );
    
    // Process order...
    
    Ok(Json(OrderResponse {
        success: true,
        order_id: data.order_id,
    }))
}
```

### Route by Event Type

```rust
pub fn create_router(state: AppState) -> Router {
    Router::new()
        .route("/", post(route_event_by_type))
        // ... other routes
        .with_state(state)
}

async fn route_event_by_type(
    TypedHeader(ce_type): TypedHeader<headers::CeType>,
    body: Bytes,
) -> Result<impl IntoResponse, AppError> {
    match ce_type.as_str() {
        "com.example.order.created" => handle_cloudevent::<OrderCreated>(body).await,
        "com.example.user.signup" => handle_cloudevent::<UserSignup>(body).await,
        "com.example.ping" => handle_cloudevent::<Ping>(body).await,
        _ => Err(AppError::UnknownEventType(ce_type.to_string())),
    }
}
```

## Testing Events Locally

### Using kn CLI

Install the Knative CLI and test with:

```bash
kn event send \
  --type com.example.ping \
  --source /local/test \
  --data '{"message": "test"}' \
  --namespace default \
  --sink http://localhost:8080/
```

### Using EventSim (local event simulator)

Create a simple event emitter:

```bash
# Send test event
curl -i -X POST \
  -H "ce-specversion: 1.0" \
  -H "ce-type: com.example.ping" \
  -H "ce-source: /test" \
  -H "ce-id: 12345" \
  -H "Content-Type: application/json" \
  -d '{"message": "test event"}' \
  http://localhost:8080/
```

### Load Testing with Events

```bash
#!/bin/bash
for i in {1..100}; do
  curl -X POST http://localhost:8080/ \
    -H "ce-specversion: 1.0" \
    -H "ce-type: com.example.ping" \
    -H "ce-source: /load-test" \
    -H "ce-id: event-$i" \
    -H "Content-Type: application/json" \
    -d "{\"message\": \"Event $i\"}" &
done
wait
echo "Sent 100 events"
```

## Observability

### View Event Logs

```bash
# Stream your service logs
make dev-logs

# Look for log entries like:
# Received CloudEvent event_id=event-123 event_type=com.example.ping source=/my-app/test
```

### Tracing Events in Jaeger

1. Open Jaeger UI: http://localhost:16686
2. Select your service from the "Service" dropdown
3. Look for traces with CloudEvent metadata

Events are traced with the following tags:
- `event_id`: CloudEvent ID
- `event_type`: CloudEvent type
- `event_source`: CloudEvent source
- `http.method`: POST
- `http.status_code`: 200

### Metrics

Events are counted in Prometheus metrics:

```promql
# Total HTTP requests (includes events)
rate(http_requests_total[5m])

# Events per service
rate(http_requests_total{handler="handle_event"}[5m])

# Event latency
histogram_quantile(0.95, http_request_duration_seconds_bucket)
```

## Best Practices

### 1. Use Structured Event Types

```rust
// ✅ Good: Specific, typed event
#[derive(Deserialize)]
pub struct PaymentProcessed {
    pub transaction_id: String,
    pub amount: Decimal,
    pub timestamp: DateTime<Utc>,
}

// ❌ Avoid: Generic object
#[derive(Deserialize)]
pub struct GenericEvent {
    pub data: serde_json::Value,
}
```

### 2. Validate Event Data

```rust
pub async fn handle_event(event: CloudEvent<Ping>) -> Result<Json<Pong>, AppError> {
    // Validate data
    if event.data.message.is_empty() {
        return Err(AppError::InvalidEvent("message cannot be empty".to_string()));
    }
    
    // Process...
    Ok(Json(Pong { /* ... */ }))
}
```

### 3. Handle Retries Gracefully

Knative may retry failed events. Design idempotent handlers:

```rust
// Use event.id() as idempotency key
pub async fn handle_event(event: CloudEvent<Ping>) -> Result<Json<Pong>, AppError> {
    let idempotency_key = event.id();
    
    // Check if already processed
    if cache.contains(idempotency_key) {
        return Ok(cached_response);
    }
    
    // Process event
    let result = process(&event).await?;
    
    // Cache result
    cache.insert(idempotency_key, result.clone());
    
    Ok(result)
}
```

### 4. Set Appropriate Timeouts

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: rust-service
spec:
  template:
    spec:
      timeoutSeconds: 300  # 5 minutes for long-running event processing
```

### 5. Monitor Dead Letter Queues

Configure a DLQ for failed events:

```yaml
apiVersion: eventing.knative.dev/v1
kind: Trigger
metadata:
  name: my-trigger
spec:
  broker: default
  subscriber:
    ref:
      apiVersion: serving.knative.dev/v1
      kind: Service
      name: my-service
  delivery:
    deadLetterSink:
      ref:
        apiVersion: serving.knative.dev/v1
        kind: Service
        name: dlq-handler
```

## Troubleshooting

### Event Not Received

1. Check service is running:
   ```bash
   make dev-status
   kubectl get ksvc
   ```

2. Verify event format:
   ```bash
   # All required headers present
   curl -v -X POST http://localhost:8080/ \
     -H "ce-specversion: 1.0" \
     -H "ce-type: com.example.test" \
     -H "ce-source: /test" \
     -H "ce-id: test-1" \
     -H "Content-Type: application/json" \
     -d '{}'
   ```

3. Check logs for parsing errors:
   ```bash
   make dev-logs | grep -i error
   ```

### High Event Latency

1. Check service scaling:
   ```bash
   kubectl get pods
   ```

2. Check resource limits:
   ```bash
   kubectl top pods
   ```

3. Review traces in Jaeger for bottlenecks

## Further Reading

- [CloudEvents Specification](https://cloudevents.io/)
- [Knative Eventing Documentation](https://knative.dev/docs/eventing/)
- [CloudEvents Cloudevents Best Practices](https://github.com/cloudevents/spec/blob/main/cloudevents/primer.md)
