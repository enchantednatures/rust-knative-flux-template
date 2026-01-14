# Kafka Event Source Integration

This guide explains how to use Apache Kafka event sources with your Knative service.


## Configuration

When you generate this template with Kafka enabled, you'll configure:
- **Topic**: Your choice (default: "events")
- **Consumer Group**: Your choice (default: "<project-name>-consumers")
- **Bootstrap Servers**: Different per environment
  - **Dev**: `kafka.kafka.svc.cluster.local:9092` (local Kafka)
  - **Staging**: User-configured external Kafka
  - **Production**: User-configured external Kafka


---

## Overview

This service integrates with Apache Kafka using Knative's **KafkaSource** event source. KafkaSource consumes messages from Kafka topics and automatically converts them to [CloudEvents](https://cloudevents.io/) before delivering them to your service.

**Architecture:**
```
Kafka Topic → KafkaSource → CloudEvent → Knative Service
                  ↓ (on failure)
             Dead Letter Queue
```

### Topic-Per-Source Pattern

This template uses a **one KafkaSource per topic** pattern:
- Each topic gets its own KafkaSource CRD
- Independent consumer groups per topic
- Separate scaling and delivery policies
- Easier monitoring and debugging

To subscribe to multiple topics, create additional KafkaSource YAML files (see [Subscribing to Multiple Kafka Topics](#subscribing-to-multiple-kafka-topics)).

---

## Prerequisites

### Knative Eventing Kafka Controller

**Local Development (Kind):**
The Kafka controller is automatically installed when you run `make dev-up`. It includes:
- Knative Eventing core
- Kafka source controller
- Kafka source data plane

**Manual Installation:**
If setting up on an existing cluster:
```bash
KNATIVE_VERSION="1.20.1"

# Install Knative Eventing
kubectl apply -f https://github.com/knative/eventing/releases/download/knative-v${KNATIVE_VERSION}/eventing-crds.yaml
kubectl apply -f https://github.com/knative/eventing/releases/download/knative-v${KNATIVE_VERSION}/eventing-core.yaml

# Install Kafka Source
kubectl apply -f https://github.com/knative-extensions/eventing-kafka-broker/releases/download/knative-v${KNATIVE_VERSION}/eventing-kafka-controller.yaml
kubectl apply -f https://github.com/knative-extensions/eventing-kafka-broker/releases/download/knative-v${KNATIVE_VERSION}/eventing-kafka-source.yaml
```

**Official Documentation:**
- [Knative Eventing](https://knative.dev/docs/eventing/)
- [Kafka Source Documentation](https://knative.dev/docs/eventing/sources/kafka-source/)
- [Installing Kafka for Knative](https://knative.dev/docs/install/eventing/kafka-install/)

---

## Local Development

### Kafka Cluster Configuration

**Automatically deployed with `make dev-up`:**
- **Namespace**: `kafka`
- **Bootstrap servers**: `kafka.kafka.svc.cluster.local:9092`

- **Partitions**: 3
- **Replication**: 1 (single node)

### KafkaSource Configuration

**Consumer Group**: `<project-name>-consumers`
**Consumers**: 3 (matches topic partitions for optimal throughput)
**Initial Offset**: `latest` (only new messages after startup)

---

## Sending Events to Kafka

### Quick Test Script

```bash
# Send a test event
make kafka-send-event

# Send custom message
./scripts/dev/send-kafka-event.sh events "My custom message"
```

### Manual Event Production

**Using kubectl exec:**
```bash
# Structured CloudEvent (recommended)
kubectl -n kafka exec -i kafka-0 -- kafka-console-producer \
  --bootstrap-server localhost:9092 \
  --topic events <<EOF
{
  "specversion": "1.0",
  "type": "com.example.user.created",
  "source": "/api/users",
  "id": "event-$(uuidgen)",
  "time": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "datacontenttype": "application/json",
  "data": {
    "userId": "12345",
    "email": "user@example.com"
  }
}
EOF
```

### CloudEvent Format Requirements

KafkaSource converts Kafka messages to CloudEvents automatically. Your message must include:

| Field | Required | Type | Description |
|--------|-----------|-------|-------------|
| `specversion` | ✅ Yes | string | CloudEvents spec version (use "1.0") |
| `type` | ✅ Yes | string | Event type (e.g., "com.example.order.created") |
| `source` | ✅ Yes | string | Event origin (e.g., "/api/orders") |
| `id` | ✅ Yes | string | Unique event identifier |
| `time` | ❌ Optional | string | ISO 8601 timestamp |
| `datacontenttype` | ❌ Optional | string | Content type of data field |
| `data` | ✅ Yes | object | Your event payload |

**Example:**
```json
{
  "specversion": "1.0",
  "type": "com.example.order.placed",
  "source": "/api/orders",
  "id": "order-12345",
  "time": "2025-12-25T12:00:00Z",
  "datacontenttype": "application/json",
  "data": {
    "orderId": "12345",
    "amount": 99.99,
    "items": [
      { "productId": "prod-1", "quantity": 2 }
    ]
  }
}
```

---

## Event Type Routing

Your service receives all events at the root `/` endpoint. You can route by event type using the `ce-type` header.

### Basic Pattern

**Example in `src/handlers/events.rs`:**
```rust
use axum::{
    extract::TypedHeader,
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use axum_cloudevents::{headers::CeType, CloudEvent};
use serde::{Deserialize, Serialize};

// Define event types
#[derive(Debug, Deserialize)]
pub struct UserCreated {
    pub user_id: String,
    pub email: String,
}

#[derive(Debug, Deserialize)]
pub struct OrderPlaced {
    pub order_id: String,
    pub amount: f64,
}

// Route by event type
pub async fn handle_event(
    TypedHeader(ce_type): TypedHeader<CeType>,
    body: String,
) -> Result<impl IntoResponse, AppError> {
    match ce_type.as_str() {
        "com.example.user.created" => {
            let event: CloudEvent<UserCreated> = serde_json::from_str(&body)?;
            handle_user_created(event).await
        }
        "com.example.order.placed" => {
            let event: CloudEvent<OrderPlaced> = serde_json::from_str(&body)?;
            handle_order_placed(event).await
        }
        _ => {
            tracing::warn!(event_type = %ce_type, "Unknown event type");
            Err(AppError::UnknownEventType(ce_type.to_string()))
        }
    }
}

async fn handle_user_created(event: CloudEvent<UserCreated>) -> Result<Json<Response>, AppError> {
    tracing::info!(
        user_id = %event.data.user_id,
        email = %event.data.email,
        "Processing user created event"
    );
    
    // Your business logic here
    
    Ok(Json(Response { success: true }))
}

async fn handle_order_placed(event: CloudEvent<OrderPlaced>) -> Result<Json<Response>, AppError> {
    tracing::info!(
        order_id = %event.data.order_id,
        amount = %event.data.amount,
        "Processing order placed event"
    );
    
    // Your business logic here
    
    Ok(Json(Response { success: true }))
}
```

### Advanced: Type Registry

For complex applications, consider creating a type registry:

```rust
pub enum EventPayload {
    UserCreated(UserCreated),
    OrderPlaced(OrderPlaced),
    PaymentProcessed(PaymentProcessed),
}

pub fn parse_event(ce_type: &str, body: &str) -> Result<EventPayload, AppError> {
    match ce_type {
        "com.example.user.created" => {
            let data: UserCreated = serde_json::from_str(body)?;
            Ok(EventPayload::UserCreated(data))
        }
        "com.example.order.placed" => {
            let data: OrderPlaced = serde_json::from_str(body)?;
            Ok(EventPayload::OrderPlaced(data))
        }
        _ => Err(AppError::UnknownEventType(ce_type.to_string()))
    }
}
```

---

## Subscribing to Multiple Kafka Topics

The template generates **one KafkaSource for one topic**. To subscribe to additional topics:

### 1. Create Additional KafkaSource YAML

**Example: `deploy/base/kafka-source-orders.yaml`**
```yaml
apiVersion: sources.knative.dev/v1beta1
kind: KafkaSource
metadata:
  name: <project-name>-kafka-source-orders
  namespace: <your-namespace>
spec:
  consumerGroup: <project-name>-orders-consumers
  consumers: 3
  bootstrapServers:
  - kafka.kafka.svc.cluster.local:9092
  topics:
  - orders  # Different topic
  sink:
    ref:
      apiVersion: serving.knative.dev/v1
      kind: Service
      name: audio-exporter  # Same service
  delivery:
    retry: 5
    backoffPolicy: exponential
    backoffDelay: PT1S
    deadLetterSink:
      ref:
        apiVersion: serving.knative.dev/v1
        kind: Service
        name: <project-name>-dlq
  initialOffset: latest
```

### 2. Add to Kustomization

**Update `deploy/base/kustomization.yaml`:**
```yaml
resources:
  - knative-service.yaml
  - kafka-source.yaml
  - kafka-source-orders.yaml  # Add new source
  - dlq-handler.yaml
```

### 3. Create Topic

```bash
make kafka-create-topic TOPIC=orders
```

### 4. Deploy

```bash
kubectl apply -k deploy/overlays/dev
```

### Benefits of Topic-Per-Source

- ✅ **Independent scaling**: Each topic can have different consumer counts
- ✅ **Separate consumer groups**: No shared offset management issues
- ✅ **Different delivery policies**: Configure retries/backs-off per topic
- ✅ **Easier monitoring**: Isolate issues per topic
- ✅ **Flexible lifecycle**: Stop/start topics independently

---

## Monitoring & Debugging

### Check KafkaSource Status

```bash
make kafka-source-status

# Or directly:
kubectl get kafkasource -n default
```

**Healthy output:**
```yaml
status:
  conditions:
  - status: "True"
    type: Ready
  - status: "True"
    type: SinkProvided
  placements:
  - podName: kafka-source-dispatcher-0
    vreplicas: 3
```

### View Consumer Lag

```bash
make kafka-consumer-lag
```

**Output shows:**
- Current offset (messages processed)
- Log end offset (total messages)
- Lag (messages behind)

### List Topics

```bash
make kafka-list-topics
```

### View Logs

```bash
# Application logs
make dev-logs

# Kafka broker logs
make kafka-logs

# Dead Letter Queue logs (failed events)
make kafka-dlq-logs
```

### Common Issues

**KafkaSource not ready:**
```bash
# Check controller is running
kubectl get pods -n knative-eventing

# Check KafkaSource events
kubectl describe kafkasource <project-name>-kafka-source
```

**No events received:**
```bash
# 1. Verify Kafka topic exists
make kafka-list-topics

# 2. Check consumer group
make kafka-consumer-lag

# 3. Produce a test event
make kafka-send-event

# 4. Check service logs
make dev-logs
```

**High consumer lag:**
- Check service scaling: `kubectl get pods`
- Review service resource limits
- Consider increasing `consumers` in KafkaSource spec
- Check if service is handling events fast enough

---

## Dead Letter Queue (DLQ)

### How It Works

When your service returns an error or times out, KafkaSource retries delivery according to the `delivery` spec:

1. **Retry up to 5 times** with exponential backoff (1s, 2s, 4s, 8s, 16s)
2. If still failing, **send to Dead Letter Queue** (`<project-name>-dlq`)
3. DLQ handler logs the failed event for investigation

### View Failed Events

```bash
make kafka-dlq-logs
```

### DLQ Handler

The template uses Knative's `event_display` container as a simple DLQ handler. This is suitable for development.

**For production**, replace the DLQ handler with a custom service:

**Edit `deploy/base/dlq-handler.yaml`:**
```yaml
spec:
  template:
    spec:
      containers:
        - name: dlq-handler
          image: <your-registry>/<your-org>/<project-name>-dlq:latest
          # Your custom DLQ handler image
```

### Custom DLQ Handler Responsibilities

Your custom DLQ handler should:
- ✅ **Log failed events**: Full event data + error reason
- ✅ **Store for review**: Save to database for manual inspection
- ✅ **Send alerts**: Notify team (Slack, PagerDuty, email)
- ✅ **Provide context**: Include retry count, original topic, error details
- ✅ **Optional: Retry**: Implement custom retry logic with different parameters

**Example DLQ handler logic:**
```rust
pub async fn handle_failed_event(event: CloudEvent<FailedEventData>) -> Result<Json<Response>, AppError> {
    // 1. Log the failure
    tracing::error!(
        event_id = %event.id(),
        original_topic = %event.extensions.get("kafkatopic"),
        retry_count = %event.extensions.get("retrycount"),
        error_message = %event.data.error,
        "Event failed delivery, sent to DLQ"
    );
    
    // 2. Store in database for review
    db::store_failed_event(&event).await?;
    
    // 3. Send alert if critical
    if event.data.is_critical {
        alerting::send_slack_alert(&event).await?;
    }
    
    Ok(Json(Response { success: true }))
}
```

---

## Production Configuration

### External Kafka Setup

For staging/prod environments, configure external Kafka clusters via overlay patches.

**Staging:** `deploy/overlays/staging/kafka-source-patch.yaml`
```yaml
spec:
  bootstrapServers:
  - kafka.staging.svc.cluster.local:9092  # Your staging Kafka
  consumers: 5
  initialOffset: earliest  # Don't miss events
```

**Production:** `deploy/overlays/prod/kafka-source-patch.yaml`
```yaml
spec:
  bootstrapServers:
  - kafka.prod.svc.cluster.local:9092  # Your production Kafka
  consumers: 10  # Scale based on load
  initialOffset: earliest
  
  delivery:
    retry: 10  # More retries in production
    backoffPolicy: exponential
    backoffDelay: PT2S
    deadLetterSink:
      ref:
        apiVersion: serving.knative.dev/v1
        kind: Service
        name: <project-name>-dlq
```

### Security (TLS/SASL)

**Add authentication to KafkaSource:**
```yaml
spec:
  net:
    tls:
      enable: true
      cert:
        secretKeyRef:
          name: kafka-tls-cert
          key: tls.crt
      key:
        secretKeyRef:
          name: kafka-tls-cert
          key: tls.key
      caCert:
        secretKeyRef:
          name: kafka-ca-cert
          key: ca.crt
    sasl:
      enable: true
      user:
        secretKeyRef:
          name: kafka-sasl-secret
          key: user
      password:
        secretKeyRef:
          name: kafka-sasl-secret
          key: password
      type:
        secretKeyRef:
          name: kafka-sasl-secret
          key: saslType  # PLAIN, SCRAM-SHA-256, SCRAM-SHA-512
```

See [Knative Kafka TLS docs](https://knative.dev/docs/eventing/sources/kafka-source/#connecting-to-a-tls-enabled-kafka-broker) for details.

---

## Best Practices

### 1. Idempotent Event Handling

Use `event.id()` as an idempotency key to prevent duplicate processing:

```rust
pub async fn handle_event(event: CloudEvent<Data>) -> Result<Json<Response>, AppError> {
    let event_id = event.id();
    
    // Check if already processed (use Redis/DB)
    if state.cache.contains(event_id).await? {
        tracing::info!(event_id = %event_id, "Event already processed, skipping");
        return Ok(Json(Response { success: true, duplicate: true }));
    }
    
    // Process event
    process_data(&event.data).await?;
    
    // Mark as processed
    state.cache.insert(event_id, true).await?;
    
    Ok(Json(Response { success: true, duplicate: false }))
}
```

### 2. Consumer Scaling

**Match consumers to partitions:**
- 3 partitions → 3 consumers (optimal)
- More consumers than partitions = idle consumers
- Fewer consumers = slower processing

**Scale based on lag:**
```bash
# Monitor lag
make kafka-consumer-lag

# If lag is high, scale up consumers
# Edit kafka-source.yaml:
spec:
  consumers: 6  # Scale up
```

### 3. Error Handling

Return appropriate HTTP codes for correct retry behavior:

| HTTP Code | Behavior | Use Case |
|------------|-------------|------------|
| 200-299 | Success, commit offset | Normal processing |
| 400-499 | Permanent failure, send to DLQ | Invalid data, business rule violations |
| 500-599 | Temporary failure, retry | Service unavailable, DB timeout |

**Example:**
```rust
pub async fn handle_event(event: CloudEvent<Data>) -> Result<impl IntoResponse, AppError> {
    match validate(&event.data) {
        Err(ValidationError) => {
            // Permanent error - don't retry
            return Err(AppError::BadRequest("Invalid data".into()));
        }
        Ok(_) => {}
    }
    
    match process(&event.data).await {
        Err(TransientError) => {
            // Temporary error - will retry
            return Err(AppError::Internal("Service unavailable".into()));
        }
        Ok(result) => Ok(Json(result))
    }
}
```

### 4. Monitoring

**Key metrics to track:**
- Consumer lag (Kafka)
- Event processing latency (service)
- DLQ message count
- Retry rate
- Error rate per event type

**Prometheus queries:**
```promql
# Event processing rate
rate(http_requests_total{handler="handle_event"}[5m])

# Error rate
rate(http_requests_total{handler="handle_event",status=~"5.."}[5m])

# DLQ delivery rate
rate(http_requests_total{service="<project-name>-dlq"}[5m])

# Consumer lag (custom metric or Kafka JMX)
kafka_consumer_lag
```

### 5. Event Design

**Use structured, versioned event types:**
```
✅ com.example.v1.user.created
✅ com.example.v2.order.placed
❌ user_created
❌ order-placed
```

**Include all required metadata:**
```json
{
  "specversion": "1.0",
  "type": "com.example.v1.user.created",
  "source": "/api/users/v1",
  "id": "user-abc123-created",
  "time": "2025-12-25T12:00:00Z",
  "data": {
    "version": "1.0",
    "userId": "12345",
    "email": "user@example.com",
    "createdAt": "2025-12-25T11:59:00Z"
  }
}
```

---

## Troubleshooting Guide

### Events Not Being Consumed

**Check 1: KafkaSource status**
```bash
kubectl get kafkasource
# Should show READY = True
```

**Check 2: Kafka source dispatcher**
```bash
kubectl get pods -n knative-eventing -l app=kafka-source-dispatcher
# Should be Running
```

**Check 3: Produce test event**
```bash
make kafka-send-event
make dev-logs  # Should see event logged
```

### High Latency

**Check 1: Consumer lag**
```bash
make kafka-consumer-lag
# If LAG > 1000, investigate
```

**Check 2: Service scaling**
```bash
kubectl get pods
# Should see multiple replicas under load
```

**Check 3: Resource limits**
```bash
kubectl top pods
# Check if hitting CPU/memory limits
```

### DLQ Receiving Events

**Check 1: View DLQ logs**
```bash
make kafka-dlq-logs
```

**Check 2: Check service errors**
```bash
make dev-logs | grep -i error
```

**Check 3: Review delivery spec**
- Is retry count too low?
- Is backoff too aggressive?
- Is service timing out?

### Kafka Connection Issues

**Check 1: Kafka broker health**
```bash
kubectl exec -n kafka kafka-0 -- kafka-broker-api-versions \
  --bootstrap-server localhost:9092
```

**Check 2: KafkaSource logs**
```bash
kubectl logs -n knative-eventing -l app=kafka-source-dispatcher
```

**Check 3: Network connectivity**
```bash
# From KafkaSource dispatcher pod
kubectl exec -n knative-eventing <dispatcher-pod> -- \
  nc -zv kafka.kafka.svc.cluster.local 9092
```

---

## Additional Resources

- **Knative Eventing**: https://knative.dev/docs/eventing/
- **Kafka Source Guide**: https://knative.dev/docs/eventing/sources/kafka-source/
- **CloudEvents Spec**: https://cloudevents.io/
- **Kafka Documentation**: https://kafka.apache.org/documentation/
- **Apache Kafka®**: https://kafka.apache.org/

---

## Next Steps

1. ✅ Review [KNATIVE_EVENTING.md](KNATIVE_EVENTING.md) for general CloudEvents usage
2. ✅ Update `src/handlers/events.rs` with your event types and business logic
3. ✅ Implement event type routing pattern for multiple event types
4. ✅ Add idempotency checks using `event.id()`
5. ✅ Configure appropriate error handling (temporary vs permanent failures)
6. ✅ Set up monitoring for consumer lag and DLQ messages
7. ✅ For multiple topics, create additional KafkaSource resources
8. ✅ In production, build custom DLQ handler service
9. ✅ Configure TLS/SASL if using secure Kafka clusters
