# Frequently Asked Questions

Common questions about {{ project_name }}.

## Table of Contents

- [General](#general)
- [Development](#development)
- [Deployment](#deployment)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)
- [Performance](#performance)

---

## General

### What is {{ project_name }}?

{{ project_name }} is a production-ready Rust microservice template built for:
- **Knative Serving**: Serverless auto-scaling
- **FluxCD**: GitOps deployment
- **OpenTelemetry**: Observability stack
{% if features contains "s3" %}
- **S3/MinIO**: Optional object storage
{% endif %}

It provides a complete starting point for building cloud-native services.

### Why Rust?

- **Performance**: Compiled to native code, fast execution
- **Safety**: Memory safety without garbage collection
- **Concurrency**: Async/await with Tokio
- **Type-Safe**: Compiler catches many errors at compile time

### Why Knative Serving?

- **Serverless**: Automatic scale-to-zero
- **Auto-scaling**: Handles traffic spikes automatically
- **Simple**: Deploy as a service, Knative handles pods
- **Industry Standard**: Used by major cloud providers

### Why FluxCD?

- **GitOps**: Infrastructure state in Git
- **Automated**: Syncs changes automatically
- **Auditable**: Full Git history of deployments
- **Reproducible**: Same environment from Git

---

## Development

### How do I start local development?

```bash
# Start development environment
make dev-up

# Run application (in another terminal)
cargo run

# Or with auto-reload
cargo watch -q -c -w src -x run

# Set up port forwarding (in another terminal)
make dev-forward
```

### What services are started with make dev-up?

- **Kind Kubernetes Cluster** - Local Kubernetes environment
- **Knative Serving** - Serverless framework
- **Redis** (port 6379) - Caching/sessions
{% if features contains "s3" %}
- **MinIO** (port 9000) - S3-compatible storage
- **MinIO Console** (port 9001) - Web UI
{% endif %}
- **OpenTelemetry Collector** (port 4317) - Telemetry collection
- **Jaeger** (port 16686) - Distributed tracing UI
- **Prometheus** (port 9090) - Metrics UI

### How do I add a new API endpoint?

1. Create handler in `src/handlers/`:

```rust
use axum::{Json, response::IntoResponse};

pub async fn my_handler() -> impl IntoResponse {
    Json(json!({"message": "Hello!"}))
}
```

2. Export in `src/handlers/mod.rs`:

```rust
mod my_handler;
pub use my_handler::my_handler;
```

3. Add route in `src/routes.rs`:

```rust
.route("/api/my-endpoint", get(handlers::my_handler))
```

### How do I run tests?

```bash
# Unit tests
cargo test

# Integration tests (requires dev environment)
make dev-up
cargo test -- --ignored --nocapture

# E2E tests
./tests/e2e/scripts/06-run-tests.sh
```

### What IDE do you recommend?

- **VS Code**: With `rust-analyzer` extension
- **CLion**: With Rust plugin
- **IntelliJ IDEA**: With Rust plugin

Recommended VS Code extensions:
- `rust-lang.rust-analyzer`
- `vadimcn.vscode-lldb`
- `tamasfe.even-better-toml`

---

## Deployment

### How do I deploy to Kubernetes?

**Manual**:
```bash
kubectl apply -k deploy/overlays/prod
```

**Via FluxCD (GitOps)**:
```bash
# Bootstrap FluxCD
flux bootstrap github --owner=your-org --repo=your-repo

# Create Kustomization
flux create kustomization {{ project_name }} \
  --source=GitRepository/{{ project_name }} \
  --path=deploy/overlays/prod
```

### What's the difference between the overlays?

- **dev**: Local development (min resources, debug logging)
- **staging**: Pre-production environment (moderate resources)
- **prod**: Production (maximum resources, warn logging)

### How do I rollback a deployment?

```bash
# Rollback to previous revision
kubectl rollout undo deployment/{{ project_name }} -n {{ project_name }}

# Rollback to specific revision
kubectl set traffic {{ project_name }} \
  --revision={{ project_name }}-00001 \
  --percent=100 \
  -n {{ project_name }}
```

### How does Knative auto-scaling work?

Knative measures:
- **Concurrent requests** per pod
- **Request latency**

Based on these metrics, it:
- Scales up when traffic increases
- Scales down when traffic decreases
- Scales to zero after 5 minutes of no traffic

**Configuration**:
```yaml
autoscaling.knative.dev/minScale: "5"
autoscaling.knative.dev/maxScale: "100"
autoscaling.knative.dev/target: "100"  # Target concurrency
```

---

## Configuration

### How do I configure the application?

Three methods (priority order):

1. **Environment Variables** (highest priority):
```bash
export APP__SERVER__PORT=9000
```

2. **Environment Config File**:
```toml
# config/development.toml
[server]
port = 9000
```

3. **Default Config File**:
```toml
# config/default.toml
[server]
port = 8080
```

### How do I manage secrets?

**Never commit secrets to Git!** Use one of these:

**Kubernetes Secrets**:
```bash
kubectl create secret generic {{ project_name }}-secrets \
  --from-literal=redis-url='redis://redis:6379' \
  {% if features contains "s3" %}--from-literal=aws-access-key-id='...' \
  --from-literal=aws-secret-access-key='...' \
  {% endif %}
```

**External Secrets Operator**:
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: {{ project_name }}-secrets
spec:
  secretStoreRef:
    name: aws-secrets-manager
  data:
  - secretKey: redis-url
    remoteRef:
      key: /{{ project_name }}/production/redis-url
```

### How do I configure {% if features contains "s3" %}S3{% else %}Redis{% endif %}?

{% if features contains "s3" %}
**Environment Variables**:
```bash
export APP__S3__ENDPOINT=https://s3.amazonaws.com
export APP__S3__BUCKET=my-bucket
export APP__S3__REGION=us-east-1
export AWS_ACCESS_KEY_ID=your-key
export AWS_SECRET_ACCESS_KEY=your-secret
```

**Config File**:
```toml
[s3]
endpoint = "https://s3.amazonaws.com"
bucket = "my-bucket"
region = "us-east-1"
```

{% else %}
**Environment Variables**:
```bash
export APP__REDIS__URL=redis://redis-cluster:6379
```

**Config File**:
```toml
[redis]
url = "redis://redis-cluster:6379"
```

{% endif %}

---

## Troubleshooting

### Why is my service not ready?

Check:
```bash
# Pod status
kubectl get pods -n {{ project_name }}

# Service status
kubectl get ksvc {{ project_name }} -n {{ project_name }}

# Pod logs
kubectl logs deployment/{{ project_name }} -n {{ project_name }}

# Service details
kubectl describe ksvc {{ project_name }} -n {{ project_name }}
```

Common causes:
- **ImagePullBackOff**: Registry credentials incorrect
- **CrashLoopBackOff**: Application error, check logs
- **ConfigMissing**: ConfigMap or Secret not found

See `docs/TROUBLESHOOTING.md` for detailed solutions.

### Why are tests failing?

```bash
# Start development environment
make dev-up

# Run tests with output
cargo test -- --nocapture

# Run integration tests
cargo test -- --ignored --nocapture
```

Common causes:
- **Services not running**: Check `make dev-status`
- **Port conflicts**: Check `lsof -i :8080`
- **Kubernetes issues**: Check `export KUBECONFIG=.kubeconfig-dev && kubectl get pods`

### Why is {% if features contains "s3" %}S3{% else %}Redis{% endif %} connection failing?

{% if features contains "s3" %}
**Check MinIO**:
```bash
# Is MinIO running?
docker ps | grep minio

# Test connectivity
curl http://localhost:9000/minio/health/live

# Check credentials
echo $AWS_ACCESS_KEY_ID
echo $AWS_SECRET_ACCESS_KEY
```

**Check bucket exists**:
```bash
docker exec -it minio mc ls local/
```

{% else %}
**Check Redis**:
```bash
# Is Redis running?
docker ps | grep redis

# Test connectivity
redis-cli -h localhost -p 6379 ping

# Check URL format
echo $APP__REDIS__URL
# Should be: redis://localhost:6379
```

{% endif %}

### Why is FluxCD not syncing?

```bash
# Check GitRepository status
kubectl get gitrepository -n {{ project_name }}

# Check Kustomization status
kubectl get kustomization -n {{ project_name }}

# Sync manually
flux reconcile kustomization {{ project_name }} -n {{ project_name }}

# Check logs
kubectl logs -n flux-system deployment/source-controller
kubectl logs -n flux-system deployment/kustomize-controller
```

---

## Performance

### How do I improve response times?

1. **Check traces** in Jaeger: Identify slow operations
2. **Check metrics** in Prometheus: High latency endpoints
3. **Optimize code**: Review slow spans
4. **Scale up**: Increase resources or replicas
5. **Cache**: Add Redis caching for frequent operations
6. **{% if features contains "s3" %}Buffer S3: Stream uploads instead of loading into memory{% else %}Use connection pooling: Increase Redis pool size{% endif %}

### How do I handle high traffic?

**Knative auto-scales automatically**, but you can tune:

```yaml
annotations:
  autoscaling.knative.dev/minScale: "10"   # Pre-warm 10 pods
  autoscaling.knative.dev/maxScale: "200"  # Scale up to 200
  autoscaling.knative.dev/target: "50"   # Target 50 concurrent req/pod
```

**Prepare for events**:
```bash
# Increase min-scale before traffic spike
kubectl patch ksvc {{ project_name }} -n {{ project_name }} \
  -p '{"spec":{"template":{"metadata":{"annotations":{"autoscaling.knative.dev/minScale":"50"}}}}}'
```

### How do I reduce cold start latency?

1. **Increase min-scale**: Keep warm pods
2. **Optimize startup**: Remove unnecessary initialization
3. **Preload data**: Load frequently used data at startup
4. **Use base image**: Optimize Dockerfile layers

```yaml
annotations:
  autoscaling.knative.dev/minScale: "1"  # Don't scale to zero
```

---

## Support

### Where can I get help?

1. **Documentation**: Read all `docs/` directory
2. **GitHub Issues**: Search or create new issue
3. **Community**: Join Slack/Discord (link in README)
4. **Email**: Contact team (link in README)

### How do I report a bug?

1. Check existing issues
2. Create new issue with:
   - Description
   - Steps to reproduce
   - Expected behavior
   - Actual behavior
   - Environment details
   - Logs/error messages

### How do I request a feature?

1. Check existing feature requests
2. Create issue with:
   - Use case
   - Proposed solution
   - Alternatives considered

---

## Additional Resources

- **Getting Started**: `docs/GETTING_STARTED.md`
- **Development**: `docs/DEVELOPMENT.md`
- **Deployment**: `docs/DEPLOYMENT.md`
- **API**: `docs/API.md`
- **Configuration**: `docs/CONFIGURATION.md`
- **Troubleshooting**: `docs/TROUBLESHOOTING.md`
