# Monitoring Guide

Complete observability guide for test-app, including distributed tracing, metrics, and logs.

## Table of Contents

- [Observability Stack](#observability-stack)
- [Distributed Tracing](#distributed-tracing)
- [Metrics](#metrics)
- [Logging](#logging)
- [Alerting](#alerting)
- [Dashboards](#dashboards)
- [Production Monitoring](#production-monitoring)

---

## Observability Stack

```
Application
    │
    ├─ Traces (OTLP/gRPC)
    ├─ Metrics (OTLP/gRPC)
    └─ Logs (Structured JSON)
         │
         ▼
┌────────────────────────┐
│ OpenTelemetry        │
│ Collector            │
└────────┬───────────────┘
         │
    ┌────┼────┐
    │         │         │
    ▼         ▼         ▼
┌──────┐  ┌─────┐  ┌──────┐
│Jaeger│  │Prometheus│
│Traces│  │Metrics│  │Loki │
└──────┘  └─────┘  │Logs │
                     └──────┘
```

**Local Development** (via make dev-up):
- Jaeger: http://localhost:16686
- Prometheus: http://localhost:9090
- OpenTelemetry Collector: http://localhost:4317

**Production**:
- Deployed to Kubernetes
- Managed observability platform (Grafana Cloud, Datadog, etc.)

---

## Distributed Tracing

### Overview

Distributed tracing tracks requests as they flow through services, providing:

- **Request Lifecycle**: From ingress to response
- **Service Dependencies**: Which services are called
- **Performance Bottlenecks**: Where time is spent
- **Root Cause Analysis**: Why requests fail

### Accessing Jaeger

**Local**: http://localhost:16686

**Production**: URL of your Jaeger instance

### Jaeger UI Features

1. **Search Traces**: Filter by service, operation, tags
2. **Trace View**: Timeline of spans across services
3. **Span Details**: Logs, tags, timing
4. **Comparison**: Compare multiple traces

### Trace Propagation

**Knative Compatibility**:
- **B3 Propagation**: Standard for service meshes
- **Trace ID**: Correlates all spans in a request
- **Span ID**: Identifies individual operations

**Flow**:
```
Request enters → Trace ID generated
    ↓
HTTP Handler → Parent span created
    ↓
Redis Call → Child span created

    ↓
Response → Parent span closed
```

### Viewing Traces

#### By Trace ID

```bash
# Get trace ID from response headers
curl -I http://localhost:8080/health/live

# View trace in Jaeger
# Navigate to: http://localhost:16686/trace/<trace-id>
```

#### By Service/Operation

1. Open Jaeger UI: http://localhost:16686
2. Select Service: `test-app`
3. Select Operation: `/api/upload`
4. Click "Find Traces"
5. Click on a trace to view details

### Custom Spans

Add custom spans to track business logic:

```rust
use tracing::{instrument, info_span, Level};

// Attribute-based
#[instrument(skip(state), fields(user_id = %user.id))]
pub async fn user_handler(
    State(state): State<AppState>,
    Path(user_id): Path<String>,
) -> impl IntoResponse {
    // ... handler logic
}

// Manual span
pub async fn complex_operation() -> Result<String, AppError> {
    let span = info_span!("complex_operation", input = "data");
    let _enter = span.enter();
    
    // Your operation here
    
    Ok("result".to_string())
}
```

### Trace Sampling

Reduce trace volume in production:

```bash
# Sample 10% of traces
export APP__TELEMETRY__SAMPLER=ratio:0.1

# Sample 1% of traces
export APP__TELEMETRY__SAMPLER=ratio:0.01

# Trace all requests (development)
export APP__TELEMETRY__SAMPLER=always
```

### Trace Analysis

**Common Patterns**:

- **High Latency**: Look for slow spans (red in Jaeger)
- **Errors**: Spans with error tags
- **Cascade Failures**: Failed spans causing downstream failures
- **N+1 Queries**: Many Redis calls in one request

**PromQL for Trace Metrics**:
```promql
# High error rate
rate(spans_dropped_total[5m]) > 0.1

# Slow requests
histogram_quantile(0.99, sum(rate(spans_duration_ms_bucket[5m])) by (le))
```

---

## Metrics

### Overview

Metrics track numerical values over time for:

- **Performance**: Request latency, throughput
- **Resources**: CPU, memory, disk
- **Business**: Requests served, errors

### Built-in Metrics

**HTTP Metrics**:
```
http_request_duration_seconds (histogram)
http_request_total (counter)
http_active_requests (gauge)
```

**Tags**:
- `method`: HTTP method (GET, POST, etc.)
- `path`: Request path
- `status`: HTTP status code (200, 404, 500, etc.)

### Accessing Prometheus

**Local**: http://localhost:9090

**Production**: URL of your Prometheus instance

### PromQL Queries

**Request Rate**:
```promql
# Requests per second
rate(http_request_total[1m])

# Requests by path
sum(rate(http_request_total[5m])) by (path)

# 95th percentile latency
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, path))
```

**Error Rate**:
```promql
# Error rate
rate(http_request_total{status=~"5.."}[5m])

# Error rate by path
sum(rate(http_request_total{status=~"5.."}[5m])) by (path)

# Error percentage
sum(rate(http_request_total{status=~"5.."}[5m])) / sum(rate(http_request_total[5m])) * 100
```



**Resource Metrics**:
```promql
# CPU usage
rate(process_cpu_seconds_total[1m])

# Memory usage
process_resident_memory_bytes

# Disk I/O
rate(process_io_read_bytes_total[1m])
```

### Custom Metrics

Create custom metrics:

```rust
use opentelemetry::{global, metrics::{Counter, Histogram, Gauge}};

pub struct MyMetrics {
    pub upload_counter: Counter<u64>,
    pub upload_size_histogram: Histogram<u64>,
    pub active_downloads: Gauge<u64>,
}

impl MyMetrics {
    pub fn new() -> Self {
        let meter = global::meter("test_app_no_s3");
        
        Self {
            upload_counter: meter
                .u64_counter("s3_upload_total")
                .with_description("Total S3 uploads")
                .init(),
            upload_size_histogram: meter
                .u64_histogram("s3_upload_size_bytes")
                .with_description("S3 upload size distribution")
                .init(),
            active_downloads: meter
                .u64_gauge("s3_active_downloads")
                .with_description("Number of active S3 downloads")
                .init(),
        }
    }
}

// Use in handler
pub async fn upload_handler(
    State(state): State<AppState>,
) -> impl IntoResponse {
    let metrics = MyMetrics::new();
    
    // Record upload
    metrics.upload_counter.add(1, &[]);
    metrics.upload_size_record(data.len(), &[]);
    
    Ok(Json(json!({"status": "ok"})))
}
```

### Exporting Metrics

**Endpoint**: `GET /metrics`

**Format**: OpenMetrics / Prometheus text format

**Example**:
```bash
curl http://localhost:8080/metrics
```

Output:
```
# HELP http_request_duration_seconds HTTP request latency
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{method="GET",path="/health/live",le="0.005"} 42
http_request_duration_seconds_bucket{method="GET",path="/health/live",le="0.01"} 45
http_request_duration_seconds_bucket{method="GET",path="/health/live",le="0.025"} 45
...
http_request_duration_seconds_sum{method="GET",path="/health/live"} 0.15
http_request_duration_seconds_count{method="GET",path="/health/live"} 45
```

### Prometheus Scraping

**Prometheus Configuration** (`docker/prometheus.yaml`):
```yaml
scrape_configs:
  - job_name: 'test-app'
    static_configs:
      - targets: ['host.docker.internal:8080']
    scrape_interval: 15s
```

**Kubernetes ServiceMonitor**:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: test-app
  namespace: test-app
spec:
  selector:
    matchLabels:
      serving.knative.dev/service: test-app
  endpoints:
  - port: http
    path: /metrics
    interval: 15s
```

---

## Logging

### Overview

Structured logs with context:

- **JSON Format**: Machine-readable
- **Trace Correlation**: Links logs to traces
- **Severity Levels**: TRACE, DEBUG, INFO, WARN, ERROR
- **Context Fields**: Request ID, user ID, etc.

### Log Format

**JSON Log Example**:
```json
{
  "timestamp": "2024-01-15T10:30:45.123Z",
  "level": "INFO",
  "target": "test_app_no_s3::handlers::api",
  "message": "Request received",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "span_id": "4d33b4a7f3ba4b6c",
  "http.method": "GET",
  "http.path": "/api/upload",
  "http.status": 200,
  "http.duration_ms": 45
}
```

### Viewing Logs

**Local**:
```bash
# Follow logs
cargo run

# With debug output
RUST_LOG=debug cargo run

# Filter by module
RUST_LOG=test_app_no_s3=debug,redis=info cargo run

# JSON logs with jq
RUST_LOG=info cargo run 2>&1 | jq '.'
```

**Kubernetes**:
```bash
# Pod logs
kubectl logs -f deployment/test-app -n test-app

# Multiple pods
kubectl logs -f -n test-app -l serving.knative.dev/service=test-app

# Previous revision
kubectl logs -f deployment/test-app --previous -n test-app

# Last 100 lines
kubectl logs --tail=100 deployment/test-app -n test-app

# Filter by trace ID
kubectl logs deployment/test-app -n test-app | grep trace-abc123
```

**Structured Log Query (jq)**:
```bash
# Find errors
kubectl logs deployment/test-app -n test-app | jq 'select(.level == "ERROR")'

# Find slow requests (> 1s)
kubectl logs deployment/test-app -n test-app | jq 'select(.http.duration_ms > 1000)'

# Group by path
kubectl logs deployment/test-app -n test-app | jq -r '.http.path' | sort | uniq -c
```

### Logging in Code

```rust
use tracing::{info, debug, warn, error, instrument};

#[instrument(skip_all, fields(user_id = user.id))]
pub async fn user_handler(user: User) -> Result<(), AppError> {
    info!("Processing user: {}", user.name);
    
    debug!("User data: {:?}", user.data);
    
    if user.age < 18 {
        warn!("User is underage: {}", user.id);
    }
    
    match process_user(user).await {
        Ok(_) => Ok(()),
        Err(e) => {
            error!("Failed to process user {}: {}", user.id, e);
            Err(e)
        }
    }
}
```

### Log Levels

| Level | Usage | Production |
|-------|--------|-------------|
| TRACE | Very verbose | ❌ Too noisy |
| DEBUG | Detailed info | ❌ Too noisy |
| INFO | Normal operation | ✅ Recommended |
| WARN | Warning conditions | ✅ Recommended |
| ERROR | Errors that don't crash | ✅ Recommended |

**Configure via Environment**:
```bash
# Development
RUST_LOG=debug cargo run

# Production
export APP__TELEMETRY__LOG_LEVEL=info
export RUST_LOG=info
```

---

## Alerting

### Recommended Alert Rules

**High Error Rate**:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: test-app-alerts
spec:
  groups:
  - name: errors
    rules:
    - alert: HighErrorRate
      expr: rate(http_request_total{status=~"5.."}[5m]) > 0.05
      for: 5m
      annotations:
        summary: "High error rate on test-app"
        description: "Error rate is {{ $value }} errors/sec for the last 5 minutes"
      labels:
        severity: warning
```

**High Latency**:
```yaml
    - alert: HighLatency
      expr: histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le)) > 1
      for: 5m
      annotations:
        summary: "High latency on test-app"
        description: "95th percentile latency is {{ $value }}s"
      labels:
        severity: warning
```

**Pod Not Ready**:
```yaml
    - alert: PodNotReady
      expr: knative_pod_status{status!="Ready"} > 0
      for: 2m
      annotations:
        summary: "Pod not ready"
        description: "{{ $value }} pods not ready"
      labels:
        severity: critical
```

### Slack Integration

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: slack-webhook
stringData:
  url: https://hooks.slack.com/services/...
---
apiVersion: notification.toolkit.fluxcd.io/v1beta1
kind: Provider
metadata:
  name: slack
spec:
  type: slack
  channel: alerts
  secretRef:
    name: slack-webhook
```

### PagerDuty Integration

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: pagerduty
stringData:
  integrationKey: YOUR_KEY
---
apiVersion: notification.toolkit.fluxcd.io/v1beta1
kind: Provider
metadata:
  name: pagerduty
spec:
  type: pagerduty
  secretRef:
    name: pagerduty
```

---

## Dashboards

### Grafana Dashboard Example

**Recommended Panels**:

1. **Request Rate**: `sum(rate(http_request_total[5m])) by (path)`
2. **Error Rate**: `sum(rate(http_request_total{status=~"5.."}[5m])) by (path)`
3. **P95 Latency**: `histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, path))`
4. **Active Requests**: `http_active_requests`
5. **CPU Usage**: `rate(process_cpu_seconds_total[1m]) * 100`
6. **Memory Usage**: `process_resident_memory_bytes`
7. **Error Log Count**: `count_over_time({level="error"}[5m])`


### Dashboard JSON Template

Import into Grafana:

```json
{
  "dashboard": {
    "title": "test-app Dashboard",
    "panels": [
      {
        "title": "Request Rate",
        "targets": [
          {
            "expr": "sum(rate(http_request_total[5m])) by (path)",
            "legendFormat": ""
          }
        ],
        "type": "graph"
      },
      {
        "title": "Error Rate",
        "targets": [
          {
            "expr": "sum(rate(http_request_total{status=~\"5..\"}[5m]))",
            "legendFormat": "Errors"
          }
        ],
        "type": "graph"
      },
      {
        "title": "P95 Latency",
        "targets": [
          {
            "expr": "histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))",
            "legendFormat": "P95"
          }
        ],
        "type": "graph"
      }
    ]
  }
}
```

---

## Production Monitoring

### Key Metrics to Monitor

**Service Health**:
- Request success rate (> 99.9%)
- P95 latency (< 500ms)
- Error rate (< 0.1%)

**Resource Utilization**:
- CPU < 70%
- Memory < 80%
- Disk < 90%

**Dependencies**:
- Redis connection success rate

- OpenTelemetry exporter health

### SLIs and SLOs

**SLI (Service Level Indicator)**:
- Metric: `http_request_total{status="200"} / http_request_total`
- Time window: 7 days rolling

**SLO (Service Level Objective)**:
- Target: 99.9% success rate
- Budget: 0.1% error budget per week

**Error Budget Calculation**:
- Requests/week: 1,000,000
- Allowed errors: 1,000
- Current errors: 50
- Remaining budget: 950 errors

### Runbooks

**High Error Rate**:
1. Check recent deployments
2. Review error logs
3. Check dependencies (Redis)
4. Scale up if resource constrained
5. Rollback if needed

**High Latency**:
1. Check traces in Jaeger
2. Identify slow operation
3. Check resource utilization
4. Review database/Redis query performance
5. Scale up or optimize code

**Pod Not Ready**:
1. Describe pod: `kubectl describe pod <pod-name>`
2. Check pod logs
3. Verify ConfigMaps and Secrets
4. Check image pull errors
5. Restart deployment

---

## Next Steps

- **API Docs**: See `docs/API.md`
- **Development**: See `docs/DEVELOPMENT.md`
- **Troubleshooting**: See `docs/TROUBLESHOOTING.md`
- **Security**: See `docs/SECURITY.md`
