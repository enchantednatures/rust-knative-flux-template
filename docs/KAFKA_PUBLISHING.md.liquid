{% if features contains "kafka" -%}
# Kafka Event Publishing from Handlers

This document provides comprehensive guidance for using Kafka event publishing in your {{ project_name }} service.

## Overview

Your service is configured to publish CloudEvents to Kafka when handlers are invoked. This enables:

- **Event-driven architecture**: Decouple handler logic from event processing
- **Event auditing**: Maintain a complete event log for compliance and debugging
- **Downstream integrations**: Enable other services to consume events in real-time
- **Asynchronous processing**: Handle long-running operations without blocking HTTP responses

## Configuration

Kafka event publishing is configured through:

### Generation-Time Configuration

During `cargo generate`, you specified:

```
Enable Kafka event publishing? yes
Kafka broker URL: {{ kafka_broker_url }}
Kafka topic name: {{ kafka_topic }}
CloudEvents event name: {{ kafka_event_name }}
```

### Environment-Specific Configuration

Configuration is loaded hierarchically:

1. **Default** (`config/default.toml`): Development defaults
2. **Environment Override** (`config/{dev,staging,prod}.toml`): Environment-specific settings
3. **Environment Variables** (`APP__KAFKA__*`): Runtime overrides

Example environment variables:

```bash
# Override broker URL
export APP__KAFKA__BROKER_URL="kafka-prod.example.com:9092"

# Override topic
export APP__KAFKA__TOPIC="events-prod"

# Override event name
export APP__KAFKA__EVENT_NAME="com.mycompany.service.v1.event.published"
```

## Publishing Events from Handlers

### Simple Example: Publishing from HTTP Handler

```rust
// In src/handlers/my_handler.rs

pub async fn my_handler(
    State(state): State<AppState>,
    Json(payload): Json<MyRequest>,
) -> Json<MyResponse> {
    // Handler logic here...
    let response = MyResponse { /* ... */ };

    // Publish event asynchronously (non-blocking)
    if let Some(publisher) = &state.kafka_publisher {
        let publisher = Arc::clone(publisher);
        let broker_url = publisher.config.broker_url.clone();
        let topic = publisher.config.topic.clone();

        tokio::spawn(async move {
            let event = crate::handlers::kafka::create_dummy_event(
                &publisher.config,
                "/api/v1/my-handler"
            );
            let event_id = event.id().to_string();

            match publisher.publish(&event).await {
                Ok((partition, offset)) => {
                    tracing::info!(
                        event_id = %event_id,
                        partition = partition,
                        offset = offset,
                        "Event published successfully"
                    );
                }
                Err(e) => {
                    let (error_type, error_context) = e.context();
                    tracing::error!(
                        error = %e,
                        error_type = %error_type,
                        error_context = %error_context,
                        event_id = %event_id,
                        broker = %broker_url,
                        topic = %topic,
                        "Failed to publish event"
                    );
                }
            }
        });
    }

    Json(response)
}
```

### Creating Custom CloudEvents

The `CloudEvent` struct follows the CloudEvents v1.0 specification:

```rust
use crate::handlers::kafka::CloudEvent;
use serde_json::json;

// Create a CloudEvent with custom data
let event = CloudEvent::new(
    "{{ kafka_event_name }}".to_string(),
    "/api/v1/custom-handler".to_string(),
    Some(json!({
        "user_id": "user-123",
        "action": "purchase",
        "amount": 99.99
    }))
);

// Serialize to JSON
let json_str = event.to_json()?;

// Serialize to bytes (for Kafka)
let bytes = event.to_json_bytes()?;
```

### Multiple Handler Pattern

When multiple handlers publish events:

```rust
// Publish from /api/v1/hello
if let Some(publisher) = &state.kafka_publisher {
    let publisher = Arc::clone(publisher);
    tokio::spawn(async move {
        let event = create_dummy_event(&publisher.config, "/api/v1/hello");
        let _ = publisher.publish(&event).await;
    });
}

// Publish from /api/v1/storage/example
if let Some(publisher) = &state.kafka_publisher {
    let publisher = Arc::clone(publisher);
    tokio::spawn(async move {
        let event = create_dummy_event(&publisher.config, "/api/v1/storage/example");
        let _ = publisher.publish(&event).await;
    });
}
```

## Error Handling

Event publishing failures do NOT affect HTTP responses. Your handler returns 200 OK even if Kafka is unavailable.

### Error Types

| Error | Cause | Recovery |
|-------|-------|----------|
| `BrokerUnreachable` | Kafka broker not responding | Automatic retry on next request |
| `PublishFailed` | Message could not be sent | Check broker logs and network |
| `TopicNotFound` | Topic does not exist | Verify topic name in config |
| `SerializationFailed` | JSON serialization error | Check event data structure |

### Error Logging

Errors are logged with full context:

```
tracing::error!(
    error = %e,
    error_type = "broker_unreachable",
    error_context = "kafka.example.com:9092 (Connection refused)",
    event_id = "550e8400-e29b-41d4-a716-446655440000",
    broker = "kafka.example.com:9092",
    topic = "{{ kafka_topic }}",
    "Failed to publish event"
);
```

Search logs by:
- `event_id`: Find specific event publication attempts
- `error_type`: Group failures by category
- `topic`: Filter by Kafka topic

## Observability

### Distributed Tracing

Each event publish operation creates a trace span:

```
Span: kafka_publish
├─ event_id: "550e8400-e29b-41d4-a716-446655440000"
├─ topic: "{{ kafka_topic }}"
├─ event_type: "{{ kafka_event_name }}"
├─ source: "/api/v1/hello"
├─ partition: 2 (on success)
├─ offset: 12345 (on success)
└─ duration: 45ms
```

View traces in Jaeger:

1. Open http://localhost:16686 (development)
2. Search for service: `{{ project_name | kebab_case }}`
3. Look for operation: `KafkaPublisher::publish`
4. Inspect span fields and timing

### Prometheus Metrics

The following metrics are exported:

#### Success Metrics

```prometheus
# Event publishing success counter
kafka_events_published_total{topic="{{ kafka_topic }}"} 1234

# Publish operation latency distribution
kafka_publish_latency_ms_bucket{topic="{{ kafka_topic }}", le="50"} 987
kafka_publish_latency_ms_bucket{topic="{{ kafka_topic }}", le="100"} 1230
kafka_publish_latency_ms_bucket{topic="{{ kafka_topic }}", le="+Inf"} 1234
```

#### Failure Metrics

```prometheus
# Event publishing failure counter
kafka_events_failed_total{topic="{{ kafka_topic }}", error_type="broker_unreachable"} 5
kafka_events_failed_total{topic="{{ kafka_topic }}", error_type="publish_failed"} 2
kafka_events_failed_total{topic="{{ kafka_topic }}", error_type="topic_not_found"} 1

# Latency of failed attempts
kafka_publish_latency_ms{topic="{{ kafka_topic }}", error="true"}
```

#### Example Prometheus Queries

```promql
# Events per second (success)
rate(kafka_events_published_total[5m])

# Events per second (failure)
rate(kafka_events_failed_total[5m])

# Publish latency p99
histogram_quantile(0.99, kafka_publish_latency_ms)

# Failure rate by error type
rate(kafka_events_failed_total[5m]) by (error_type)

# Topic-specific throughput
sum by (topic) (rate(kafka_events_published_total[5m]))
```

### Health Checks

The readiness probe (`/health/ready`) includes Kafka broker connectivity checks:

```bash
# Healthy (all dependencies reachable)
curl http://localhost:8080/health/ready
# Returns 200 OK with status="ready"

# Unhealthy (Kafka broker unreachable)
curl http://localhost:8080/health/ready
# Returns 503 Service Unavailable
```

## Testing

### Unit Tests

Test CloudEvent generation:

```bash
cargo test --lib handlers::kafka::tests::test_cloud_event_generation
```

Test error handling:

```bash
cargo test --lib handlers::kafka::tests::test_kafka_error_context
```

### Integration Tests

Test with embedded Kafka (requires Docker):

```bash
# Run Kafka integration tests
cargo test --test kafka_publishing_test -- --nocapture

# Skip if Docker not available
# Tests will auto-detect and skip with warning
```

### E2E Tests

Test complete flow in Kind cluster:

```bash
# Deploy service with Kafka enabled
cargo generate --git <repo> --name my-service <<EOF
my-service
y  # enable kafka
kafka.kafka.svc.cluster.local:9092
events
com.example.event.published
y  # enable image updates
default
myorg
my-service
main
ghcr.io
y  # use default scaling
EOF

# Run E2E tests
./tests/e2e/scripts/kafka-test.sh
```

## Production Deployment

### Prerequisites

1. **Kafka Cluster**: Running and accessible at `{{ kafka_broker_url }}`
2. **Topic Provisioning**: Topic `{{ kafka_topic }}` exists with sufficient partitions
3. **Network Policy**: Service can reach Kafka broker (firewall, security groups)
4. **Monitoring**: Prometheus scraping `/metrics` endpoint

### Kafka Topic Configuration

Recommended topic settings:

```bash
kafka-topics --create \
  --bootstrap-server {{ kafka_broker_url }} \
  --topic {{ kafka_topic }} \
  --partitions 3 \
  --replication-factor 3 \
  --config retention.ms=604800000 \
  --config compression.type=snappy
```

Configuration rationale:
- **3 partitions**: Distribute load across brokers
- **3 replication**: Fault tolerance (requires 3+ brokers)
- **7-day retention**: Balance storage with historical access
- **Snappy compression**: Reduce network bandwidth (matches app config)

### Environment Variables

Set for your deployment:

```yaml
# Kubernetes manifest example
env:
  - name: APP__KAFKA__BROKER_URL
    value: "kafka-prod.example.com:9092"
  - name: APP__KAFKA__TOPIC
    value: "{{ project_name }}-events"
  - name: APP__KAFKA__EVENT_NAME
    value: "com.mycompany.{{ project_name }}.v1.event.published"
```

### Monitoring Setup

1. **Prometheus Scrape Config**:

```yaml
scrape_configs:
  - job_name: '{{ project_name }}'
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_app]
        action: keep
        regex: {{ project_name }}
```

2. **Alert Rules**:

```yaml
groups:
  - name: kafka_publishing
    rules:
      - alert: HighKafkaPublishFailureRate
        expr: |
          (rate(kafka_events_failed_total[5m]) / 
           rate(kafka_events_published_total[5m])) > 0.01
        for: 5m
        annotations:
          summary: "{{ project_name }} has >1% Kafka publish failures"
      
      - alert: KafkaPublishLatencyHigh
        expr: |
          histogram_quantile(0.99, kafka_publish_latency_ms) > 1000
        for: 5m
        annotations:
          summary: "{{ project_name }} p99 publish latency >1s"
```

3. **Grafana Dashboard**:

Use metrics to create dashboard panels:
- Publish success/failure rates over time
- Latency percentiles (p50, p95, p99)
- Error rate by type
- Topic throughput

## CloudEvents Schema

Published events follow CloudEvents v1.0 specification:

```json
{
  "specversion": "1.0",
  "type": "{{ kafka_event_name }}",
  "source": "/api/v1/handler",
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "time": "2026-01-04T12:34:56Z",
  "datacontenttype": "application/json",
  "data": {
    "message": "Event published from handler",
    "timestamp": "2026-01-04T12:34:56Z"
  }
}
```

Fields:
- **specversion**: CloudEvents spec version (always "1.0")
- **type**: Event type (configured: `{{ kafka_event_name }}`)
- **source**: Origin of event (handler path)
- **id**: Unique event identifier (UUID v4)
- **time**: Event timestamp (RFC3339, UTC)
- **datacontenttype**: Payload format (always "application/json")
- **data**: Event payload (optional)

## Troubleshooting

### Broker Connection Issues

**Symptom**: Readiness probe fails, error logs show "broker unreachable"

**Diagnosis**:
```bash
# Check broker is running
kafka-broker-api-versions --bootstrap-server {{ kafka_broker_url }}

# Check network connectivity
nc -zv {{ kafka_broker_url | split: ":" | first }} {{ kafka_broker_url | split: ":" | last }}
```

**Resolution**:
- Verify `APP__KAFKA__BROKER_URL` is correct
- Check firewall/security group allows traffic
- Ensure Kafka broker is healthy
- Check DNS resolution if using hostnames

### Topic Not Found

**Symptom**: Error logs show "topic not found"

**Diagnosis**:
```bash
# List available topics
kafka-topics --list --bootstrap-server {{ kafka_broker_url }}
```

**Resolution**:
- Create topic: `kafka-topics --create --bootstrap-server {{ kafka_broker_url }} --topic {{ kafka_topic }}`
- Verify topic name matches config (`{{ kafka_topic }}`)
- Check broker permissions

### High Latency

**Symptom**: Prometheus metric `kafka_publish_latency_ms` > 1000ms

**Diagnosis**:
```bash
# Check broker metrics
kafka-consumer-groups --bootstrap-server {{ kafka_broker_url }} --group {{ project_name }} --describe

# Check network latency
ping {{ kafka_broker_url | split: ":" | first }}
```

**Resolution**:
- Check broker CPU/disk usage
- Verify network latency to broker
- Increase topic partitions for parallelism
- Adjust `APP__KAFKA__LINGER_MS` if needed

### Events Not Appearing in Topic

**Symptom**: No events visible in Kafka topic

**Diagnosis**:
```bash
# Check topic has messages
kafka-console-consumer --bootstrap-server {{ kafka_broker_url }} \
  --topic {{ kafka_topic }} \
  --from-beginning \
  --max-messages 1
```

**Resolution**:
- Verify handler is being invoked (check HTTP response 200 OK)
- Check application logs for publish errors
- Verify Kafka topic is readable (permissions)
- Confirm event serialization succeeds

## References

- [CloudEvents Specification](https://cloudevents.io/)
- [Apache Kafka Documentation](https://kafka.apache.org/documentation/)
- [Rust rdkafka Client](https://github.com/fede1024/rust-rdkafka)
- [OpenTelemetry Observability](https://opentelemetry.io/)

{% else -%}

# Kafka Event Publishing Not Enabled

Kafka event publishing is not enabled for this service. To enable it:

1. Regenerate project with `cargo generate`:
   - Select "yes" when prompted for Kafka event publishing
   - Provide broker URL, topic name, and event name

2. Or add manually:
   - Include "kafka" in the `features` array in `cargo-generate.toml`
   - Provide broker URL, topic, and event name when prompted
   - Update configuration templates with Kafka settings

See [KAFKA_EVENTING.md](./KAFKA_EVENTING.md) for event source (Knative Eventing) documentation.

{% endif -%}
