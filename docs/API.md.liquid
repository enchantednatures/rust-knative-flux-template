# API Reference

Complete reference for {{ project_name }} HTTP endpoints, request/response formats, and examples.

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
{% if features contains "s3" %}- S3/MinIO connectivity{% endif %}

**Response on Success**: 200 OK

```bash
curl http://localhost:8080/health/ready
```

**Response Body**:
```json
{
  "status": "ready",
  "checks": {
    "redis": "healthy"{% if features contains "s3" %},
    "s3": "healthy"{% endif %}
  },
  "timestamp": "2024-01-15T10:30:45Z"
}
```

**Response on Failure**: 503 Service Unavailable

```json
{
  "status": "not_ready",
  "checks": {
    "redis": "unhealthy"{% if features contains "s3" %},
    "s3": "healthy"{% endif %}
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

{% if features contains "s3" %}

## Storage Endpoints

### Upload Object

**Endpoint**: `POST /api/upload`

**Purpose**: Upload an object to the storage bucket

**Request Headers**:
```
Content-Type: application/json
```

**Request Body**:
```json
{
  "key": "path/to/object.txt",
  "data": "base64-encoded-data"
}
```

**Parameters**:
- `key` (string, required): Object path in bucket (e.g., `documents/report.pdf`)
- `data` (string, required): Base64-encoded file content

**Response**: 201 Created

```bash
# Example: Upload a text file
CONTENT=$(echo "Hello, World!" | base64)
curl -X POST http://localhost:8080/api/upload \
  -H "Content-Type: application/json" \
  -d "{\"key\": \"test.txt\", \"data\": \"$CONTENT\"}"
```

**Response Body**:
```json
{
  "key": "test.txt",
  "size": 13,
  "timestamp": "2024-01-15T10:30:45Z"
}
```

**Error Responses**:
- `400 Bad Request`: Invalid JSON or missing required fields
- `500 Internal Server Error`: S3 operation failed

**Example (Python)**:
```python
import requests
import base64

with open('report.pdf', 'rb') as f:
    data = base64.b64encode(f.read()).decode('utf-8')

response = requests.post('http://localhost:8080/api/upload', json={
    'key': 'documents/report.pdf',
    'data': data
})

print(response.json())  # {'key': 'documents/report.pdf', 'size': 45678, ...}
```

---

### Download Object

**Endpoint**: `GET /api/download/:key`

**Purpose**: Download an object from the storage bucket

**Parameters**:
- `key` (path parameter, required): Object path in bucket

**Response**: 200 OK with binary content

```bash
curl http://localhost:8080/api/download/test.txt -o test.txt
```

**Response Headers**:
```
Content-Type: application/octet-stream
Content-Length: 13
Last-Modified: 2024-01-15T10:30:45Z
```

**Response Body**: Binary file content

**Error Responses**:
- `404 Not Found`: Object does not exist
- `500 Internal Server Error`: S3 operation failed

**Example (Python)**:
```python
import requests
import base64

response = requests.get('http://localhost:8080/api/download/documents/report.pdf')

with open('report.pdf', 'wb') as f:
    f.write(response.content)
```

---

### List Objects

**Endpoint**: `GET /api/objects`

**Purpose**: List all objects in the bucket with optional prefix filtering

**Query Parameters**:
- `prefix` (string, optional): Filter objects by path prefix (e.g., `documents/`)
- `limit` (integer, optional): Max objects to return (default: 1000)

**Response**: 200 OK

```bash
# List all objects
curl http://localhost:8080/api/objects

# List with prefix
curl "http://localhost:8080/api/objects?prefix=documents/"

# List with limit
curl "http://localhost:8080/api/objects?limit=100"
```

**Response Body**:
```json
{
  "objects": [
    {
      "key": "test.txt",
      "size": 13,
      "modified": "2024-01-15T10:30:45Z"
    },
    {
      "key": "documents/report.pdf",
      "size": 45678,
      "modified": "2024-01-15T10:35:20Z"
    }
  ],
  "count": 2,
  "prefix": null
}
```

**Error Responses**:
- `500 Internal Server Error`: S3 list operation failed

**Example (Python)**:
```python
import requests

response = requests.get('http://localhost:8080/api/objects', params={
    'prefix': 'documents/',
    'limit': 50
})

data = response.json()
for obj in data['objects']:
    print(f"{obj['key']} ({obj['size']} bytes)")
```

---

### Get Object Metadata

**Endpoint**: `HEAD /api/stat/:key`

**Purpose**: Get object metadata without downloading content

**Parameters**:
- `key` (path parameter, required): Object path in bucket

**Response**: 200 OK with metadata headers

```bash
curl -I http://localhost:8080/api/stat/test.txt
```

**Response Headers**:
```
Content-Type: application/octet-stream
Content-Length: 13
Last-Modified: 2024-01-15T10:30:45Z
ETag: "abc123def456"
```

**Response Body**: Empty (HEAD request)

**Error Responses**:
- `404 Not Found`: Object does not exist
- `500 Internal Server Error`: S3 stat operation failed

**Example (Python)**:
```python
import requests

response = requests.head('http://localhost:8080/api/stat/documents/report.pdf')

print(f"Size: {response.headers.get('Content-Length')} bytes")
print(f"Modified: {response.headers.get('Last-Modified')}")
print(f"ETag: {response.headers.get('ETag')}")
```

---

### Delete Object

**Endpoint**: `DELETE /api/delete/:key`

**Purpose**: Delete an object from the storage bucket

**Parameters**:
- `key` (path parameter, required): Object path in bucket

**Response**: 204 No Content

```bash
curl -X DELETE http://localhost:8080/api/delete/test.txt
```

**Response Body**: Empty

**Error Responses**:
- `404 Not Found`: Object does not exist
- `500 Internal Server Error`: S3 delete operation failed

**Example (Python)**:
```python
import requests

response = requests.delete('http://localhost:8080/api/delete/documents/report.pdf')

if response.status_code == 204:
    print("Object deleted successfully")
elif response.status_code == 404:
    print("Object not found")
```

---

## Storage Request/Response Examples

### Complete Upload-Download Cycle

**1. Upload file**:
```bash
# Create a test file
echo "Important data" > myfile.txt

# Upload it
curl -X POST http://localhost:8080/api/upload \
  -H "Content-Type: application/json" \
  -d @- <<EOF
{
  "key": "backups/myfile.txt",
  "data": "$(base64 < myfile.txt)"
}
EOF
```

**Response**:
```json
{
  "key": "backups/myfile.txt",
  "size": 14,
  "timestamp": "2024-01-15T10:30:45Z"
}
```

**2. List objects with prefix**:
```bash
curl http://localhost:8080/api/objects?prefix=backups/
```

**Response**:
```json
{
  "objects": [
    {
      "key": "backups/myfile.txt",
      "size": 14,
      "modified": "2024-01-15T10:30:45Z"
    }
  ],
  "count": 1,
  "prefix": "backups/"
}
```

**3. Check file metadata**:
```bash
curl -I http://localhost:8080/api/stat/backups/myfile.txt
```

**Response**:
```
HTTP/1.1 200 OK
Content-Type: application/octet-stream
Content-Length: 14
Last-Modified: 2024-01-15T10:30:45Z
Date: Mon, 15 Jan 2024 10:35:20 GMT
```

**4. Download file**:
```bash
curl http://localhost:8080/api/download/backups/myfile.txt -o downloaded.txt
cat downloaded.txt  # Output: Important data
```

**5. Delete file**:
```bash
curl -X DELETE http://localhost:8080/api/delete/backups/myfile.txt
```

Response: HTTP 204 No Content

{% else %}

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

{% endif %}

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
{% if features contains "s3" %}| S3 Operation | 30s | OpenDAL default |{% endif %}
| Readiness Check | 5s | Kubernetes probe timeout |

---

## Examples by Language

### cURL

{% if features contains "s3" %}
```bash
# Upload
curl -X POST http://localhost:8080/api/upload \
  -H "Content-Type: application/json" \
  -d '{"key":"file.txt","data":"aGVsbG8="}'

# Download
curl http://localhost:8080/api/download/file.txt

# List
curl http://localhost:8080/api/objects

# Delete
curl -X DELETE http://localhost:8080/api/delete/file.txt
```
{% else %}
```bash
# Health checks
curl http://localhost:8080/health/live
curl http://localhost:8080/health/ready

# Metrics
curl http://localhost:8080/metrics
```
{% endif %}

### JavaScript/Node.js

{% if features contains "s3" %}
```javascript
// Upload
const response = await fetch('http://localhost:8080/api/upload', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    key: 'file.txt',
    data: Buffer.from('hello').toString('base64')
  })
});

// Download
const blob = await fetch('http://localhost:8080/api/download/file.txt')
  .then(r => r.blob());

// List
const files = await fetch('http://localhost:8080/api/objects')
  .then(r => r.json());

// Delete
await fetch('http://localhost:8080/api/delete/file.txt', {
  method: 'DELETE'
});
```
{% else %}
```javascript
// Health check
const health = await fetch('http://localhost:8080/health/ready')
  .then(r => r.json());

// Metrics
const metrics = await fetch('http://localhost:8080/metrics')
  .then(r => r.text());
```
{% endif %}

### Python

{% if features contains "s3" %}
```python
import requests
import base64

# Upload
with open('file.txt', 'rb') as f:
    data = base64.b64encode(f.read()).decode()

requests.post('http://localhost:8080/api/upload', json={
    'key': 'file.txt',
    'data': data
})

# Download
r = requests.get('http://localhost:8080/api/download/file.txt')
with open('downloaded.txt', 'wb') as f:
    f.write(r.content)

# List
files = requests.get('http://localhost:8080/api/objects').json()

# Delete
requests.delete('http://localhost:8080/api/delete/file.txt')
```
{% else %}
```python
import requests

# Health check
health = requests.get('http://localhost:8080/health/ready').json()

# Metrics
metrics = requests.get('http://localhost:8080/metrics').text
```
{% endif %}

### Rust

{% if features contains "s3" %}
```rust
use reqwest::Client;
use serde_json::json;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let client = Client::new();
    
    // Upload
    let response = client
        .post("http://localhost:8080/api/upload")
        .json(&json!({
            "key": "file.txt",
            "data": base64::encode("hello")
        }))
        .send()
        .await?;
    
    // Download
    let data = client
        .get("http://localhost:8080/api/download/file.txt")
        .send()
        .await?
        .bytes()
        .await?;
    
    // List
    let objects = client
        .get("http://localhost:8080/api/objects")
        .send()
        .await?
        .json::<serde_json::Value>()
        .await?;
    
    // Delete
    client
        .delete("http://localhost:8080/api/delete/file.txt")
        .send()
        .await?;
    
    Ok(())
}
```
{% else %}
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
{% endif %}

---

## Next Steps

- See `docs/DEVELOPMENT.md` for adding custom endpoints
- See `docs/MONITORING.md` for metrics details
- See `docs/TROUBLESHOOTING.md` for common API errors
