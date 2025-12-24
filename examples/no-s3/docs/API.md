# API Reference

Complete reference for example-app HTTP endpoints, request/response formats, and examples.

## Base URL and Versioning

**Base URL**: `http://localhost:8080` (local) or service URL from Knative (production)

**API Version**: Currently unversioned (v1 coming in future releases)

All endpoints return JSON responses unless otherwise noted.

## Health Endpoints

Health endpoints are used by Knative for liveness and readiness probes.

### Liveness Probe

**Endpoint**: `GET /health/live`

**Purpose**: Is the service alive? Always returns 200 even if dependencies are down.

**Response**: 200 OK

```bash
curl http://localhost:8080/health/live
```

**Response Body**:
```json
{
  "status": "alive",
  "timestamp": "2024-01-15T10:30:45Z"
}
```

**Use Case**: Kubernetes liveness probe to restart unhealthy pods

---

### Readiness Probe

**Endpoint**: `GET /health/ready`

**Purpose**: Is the service ready to handle traffic? Checks critical dependencies.

**Checks**:
- Redis connection


**Response on Success**: 200 OK

```bash
curl http://localhost:8080/health/ready
```

**Response Body**:
```json
{
  "status": "ready",
  "checks": {
    "redis": "healthy"
  },
  "timestamp": "2024-01-15T10:30:45Z"
}
```

**Response on Failure**: 503 Service Unavailable

```json
{
  "status": "not_ready",
  "checks": {
    "redis": "unhealthy"
  },
  "error": "Redis connection failed",
  "timestamp": "2024-01-15T10:30:45Z"
}
```

**Use Case**: Kubernetes readiness probe to remove from load balancer

---

## Metrics Endpoint

### Prometheus Metrics

**Endpoint**: `GET /metrics`

**Format**: OpenMetrics (Prometheus text format)

**Purpose**: Scrape application metrics for monitoring

```bash
curl http://localhost:8080/metrics
```

**Response** (sample):
```
# HELP http_request_duration_seconds HTTP request latency
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{method="GET",path="/health/live",le="0.005"} 42
http_request_duration_seconds_bucket{method="GET",path="/health/live",le="0.01"} 45
http_request_duration_seconds_bucket{method="GET",path="/health/live",le="0.025"} 45
http_request_duration_seconds_bucket{method="GET",path="/health/live",le="0.05"} 45
...
http_request_duration_seconds_sum{method="GET",path="/health/live"} 0.15
http_request_duration_seconds_count{method="GET",path="/health/live"} 45

# HELP http_request_total HTTP request count
# TYPE http_request_total counter
http_request_total{method="GET",path="/health/live",status="200"} 45
```

**Metrics Exposed**:
- `http_request_duration_seconds` (histogram) - Request latency by method, path, status
- `http_request_total` (counter) - Request count by method, path, status
- `http_active_requests` (gauge) - Currently active requests
- Custom application metrics (see `docs/MONITORING.md`)

**Use Case**: Prometheus scraping, alerting, dashboards

---



## Additional Endpoints

For a service without S3 storage, you can add custom API endpoints:

### Adding New Endpoints

Edit `src/routes.rs`:
```rust
pub fn routes() -> Router {
    Router::new()
        .route("/api/hello", get(handlers::hello))
        .route("/api/data/:id", get(handlers::get_data))
        .route("/api/data", post(handlers::create_data))
}
```

Edit `src/handlers/api.rs`:
```rust
pub async fn hello() -> impl IntoResponse {
    Json(json!({"message": "Hello, World!"}))
}

pub async fn get_data(
    Path(id): Path<String>,
) -> impl IntoResponse {
    Json(json!({"id": id, "data": "example"}))
}
```



---

## Error Handling

All error responses follow a consistent format:

**Standard Error Response**:
```json
{
  "error": "Descriptive error message",
  "status": 400,
  "timestamp": "2024-01-15T10:30:45Z",
  "request_id": "req-abc123"
}
```

**HTTP Status Codes**:

| Code | Meaning | Example |
|------|---------|---------|
| 200 | OK | Health check passed, data retrieved |
| 201 | Created | Object uploaded |
| 204 | No Content | Object deleted |
| 400 | Bad Request | Invalid JSON, missing parameters |
| 404 | Not Found | Endpoint not found, object not found |
| 503 | Service Unavailable | Dependencies unhealthy (readiness probe) |
| 500 | Internal Server Error | Unexpected error (Redis/S3 failure) |

---

## Rate Limiting

Currently not implemented. Rate limiting can be added via middleware:

```rust
use tower_http::limit::ConcurrencyLimitLayer;

let app = Router::new()
    .layer(ConcurrencyLimitLayer::max(100));
```

---

## Request Tracing

Every request automatically gets a trace ID:

```
Request-ID: req-4bf92f3577b34da6a3ce929d0e0e4736
Trace-ID: 4bf92f3577b34da6a3ce929d0e0e4736 (B3 format)
Span-ID: 4d33b4a7f3ba4b6c
```

These IDs appear in:
- Response headers
- Application logs
- Jaeger traces
- Prometheus metrics

Use request ID to correlate logs and traces:
```bash
# View logs for a specific request
kubectl logs -f deployment/my-service | grep req-abc123

# Find trace in Jaeger with trace ID
# Navigate to: http://localhost:16686/trace/4bf92f3577b34da6a3ce929d0e0e4736
```

---

## Timeouts

Default timeout behavior:

| Operation | Timeout | Notes |
|-----------|---------|-------|
| HTTP Request | 30s | Configurable via middleware |
| Redis Operation | 5s | Connection timeout |

| Readiness Check | 5s | Kubernetes probe timeout |

---

## Examples by Language

### cURL


```bash
# Health checks
curl http://localhost:8080/health/live
curl http://localhost:8080/health/ready

# Metrics
curl http://localhost:8080/metrics
```


### JavaScript/Node.js


```javascript
// Health check
const health = await fetch('http://localhost:8080/health/ready')
  .then(r => r.json());

// Metrics
const metrics = await fetch('http://localhost:8080/metrics')
  .then(r => r.text());
```


### Python


```python
import requests

# Health check
health = requests.get('http://localhost:8080/health/ready').json()

# Metrics
metrics = requests.get('http://localhost:8080/metrics').text
```


### Rust


```rust
use reqwest::Client;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let client = Client::new();
    
    // Health check
    let health = client
        .get("http://localhost:8080/health/ready")
        .send()
        .await?
        .json::<serde_json::Value>()
        .await?;
    
    println!("{}", health);
    
    Ok(())
}
```


---

## Next Steps

- See `docs/DEVELOPMENT.md` for adding custom endpoints
- See `docs/MONITORING.md` for metrics details
- See `docs/TROUBLESHOOTING.md` for common API errors
