# Troubleshooting Guide

Common issues, error messages, and solutions for example-app.

## Table of Contents

- [Local Development Issues](#local-development-issues)
- [Kubernetes Issues](#kubernetes-issues)
- [Runtime Errors](#runtime-errors)
- [FluxCD Issues](#fluxcd-issues)
- [Performance Issues](#performance-issues)
- [Debugging Techniques](#debugging-techniques)
- [Getting Help](#getting-help)

---

## Local Development Issues

### Redis Connection Refused

**Symptoms**:
```
Error: Connection refused (os error 61)
Error: Redis connection failed
```

**Solutions**:

1. Check if Redis is running:
```bash
docker-compose ps redis
```

2. Start Redis:
```bash
docker-compose up -d redis
```

3. Check Redis logs:
```bash
docker-compose logs redis
```

4. Test Redis connection:
```bash
redis-cli -h localhost -p 6379 ping
# Expected output: PONG
```

5. Verify Redis URL in config:
```bash
cat config/development.toml | grep redis
# Should show: url = "redis://localhost:6379"
```



### Port Already in Use

**Symptoms**:
```
Error: Os { code: 48, kind: AddrInUse, message: "Address already in use" }
Error: Failed to bind to address 0.0.0.0:8080
```

**Solutions**:

1. Find process using port:
```bash
lsof -i :8080
# or
netstat -tulpn | grep 8080
```

2. Kill the process:
```bash
kill -9 <PID>
```

3. Use different port:
```bash
APP__SERVER__PORT=9000 cargo run
```

### Build Failures

**Symptoms**:
```
error[E0432]: unresolved import `crate::module`
error: failed to compile
```

**Solutions**:

1. Clean build cache:
```bash
cargo clean
```

2. Update dependencies:
```bash
cargo update
```

3. Check Rust version:
```bash
rustc --version
# Should be 1.92+
```

4. Check for syntax errors:
```bash
cargo clippy --all-targets
```

5. Verify module exports:
```bash
cat src/lib.rs
# Should export all modules
```

---

## Kubernetes Issues

### Knative Service Not Ready

**Symptoms**:
```
kubectl get ksvc example-app
# Shows: Ready: False
```

**Solutions**:

1. Describe service:
```bash
kubectl describe ksvc example-app -n example-app
```

2. Check pod status:
```bash
kubectl get pods -n example-app -l serving.knative.dev/service=example-app
```

3. View pod logs:
```bash
kubectl logs -f deployment/example-app -n example-app
```

4. Check conditions:
```bash
kubectl get ksvc example-app -n example-app -o jsonpath='{.status.conditions}'
```

5. Common conditions:
- `ConfigurationsReady: False` - ConfigMap/Secret missing
- `Ready: False` - Pod not running
- `RoutesReady: False` - Networking issue

### ImagePullBackOff

**Symptoms**:
```
kubectl get pods
# Shows: ImagePullBackOff
```

**Solutions**:

1. Describe pod:
```bash
kubectl describe pod <pod-name> -n example-app
```

2. Check error message:
```
Failed to pull image "ghcr.io/enchantednatures/example-app:latest":
rpc error: code = Unknown desc = Error pulling image: unauthorized
```

3. Verify registry credentials:
```bash
kubectl get secret registry-credentials -n example-app -o yaml
```

4. Create registry secret:
```bash
kubectl create secret docker-registry registry-credentials \
  --docker-server=ghcr.io \
  --docker-username=USERNAME \
  --docker-password=PASSWORD \
  -n example-app
```

5. Update image reference:
```bash
kubectl set image deployment/example-app user-container=ghcr.io/enchantednatures/example-app:latest
```

### CrashLoopBackOff

**Symptoms**:
```
kubectl get pods
# Shows: CrashLoopBackOff
```

**Solutions**:

1. View pod logs:
```bash
kubectl logs <pod-name> -n example-app
```

2. View previous container logs:
```bash
kubectl logs <pod-name> -n example-app --previous
```

3. Check pod events:
```bash
kubectl describe pod <pod-name> -n example-app
```

4. Common causes:
- **OOMKilled**: Increase memory limit
- **Exit code 1**: Application error, check logs
- **Exit code 137**: Container killed, check resource limits

5. Edit resource limits:
```bash
kubectl edit deployment example-app -n example-app
# Increase memory/cpu limits
```

### ConfigMap or Secret Not Found

**Symptoms**:
```
Error: ConfigMap "app-config" not found
Error: Secret "app-secrets" not found
```

**Solutions**:

1. Check if ConfigMap exists:
```bash
kubectl get configmaps -n example-app
```

2. Check if Secret exists:
```bash
kubectl get secrets -n example-app
```

3. Create missing ConfigMap:
```bash
kubectl create configmap example-app-config \
  --from-file=config/production.toml \
  -n example-app
```

4. Create missing Secret:
```bash
kubectl create secret generic example-app-secrets \
  --from-literal=redis-url='redis://redis:6379' \
  
  -n example-app
```

5. Verify environment variable injection:
```bash
kubectl describe deployment example-app -n example-app
# Check env: section
```

---

## Runtime Errors

### Redis Timeout

**Symptoms**:
```
Error: Redis connection timeout
Error: IO error: Timed out
```

**Solutions**:

1. Check Redis health:
```bash
kubectl exec -it redis-0 -n redis -- redis-cli ping
```

2. Check network connectivity:
```bash
kubectl run debug --image=busybox --rm -it --restart=Never \
  -n example-app -- sh -c "nc -zv redis 6379"
```

3. Increase Redis timeout in config:
```bash
export APP__REDIS__TIMEOUT_SECS=10
```

4. Check Redis connection pool:
```bash
# Monitor Redis connections
redis-cli -h <redis-host> -p 6379 CLIENT LIST
```



### Memory Limit Exceeded

**Symptoms**:
```
OOMKilled
Error: process killed; out of memory
```

**Solutions**:

1. Check pod resource limits:
```bash
kubectl get pod <pod-name> -n example-app -o jsonpath='{.spec.containers[0].resources.limits}'
```

2. Increase memory limit:
```yaml
resources:
  limits:
    memory: "1Gi"  # Increased from 512Mi
```

3. Monitor memory usage:
```bash
kubectl top pod <pod-name> -n example-app
```

4. Check for memory leaks:
```bash
# Profile memory usage
cargo flamegraph --root --no-inline
```

---

## FluxCD Issues

### GitRepository Not Syncing

**Symptoms**:
```
kubectl get gitrepository -n example-app
# Shows: Ready: False
```

**Solutions**:

1. Describe GitRepository:
```bash
kubectl describe gitrepository example-app -n example-app
```

2. Check conditions:
```bash
kubectl get gitrepository example-app -n example-app -o jsonpath='{.status.conditions}'
```

3. Check authentication:
```bash
# Verify SSH key
ssh -T git@github.com

# Verify token
curl -H "Authorization: token <token>" https://api.github.com/user
```

4. Sync manually:
```bash
flux reconcile source git example-app -n example-app
```

5. Check FluxCD logs:
```bash
kubectl logs -n flux-system deployment/source-controller
```

### Kustomization Failed

**Symptoms**:
```
kubectl get kustomization -n example-app
# Shows: Ready: False
```

**Solutions**:

1. Describe Kustomization:
```bash
kubectl describe kustomization example-app -n example-app
```

2. Check error message:
```bash
kubectl get kustomization example-app -n example-app -o yaml | grep -A 10 status
```

3. Validate Kustomization locally:
```bash
kubectl kustomize deploy/overlays/prod
```

4. Check syntax errors:
```bash
yamllint deploy/overlays/prod/*.yaml
```

5. Sync manually:
```bash
flux reconcile kustomization example-app -n example-app
```

6. Check FluxCD logs:
```bash
kubectl logs -n flux-system deployment/kustomize-controller
```

### Image Not Updating

**Symptoms**:
```
New image pushed but deployment not updated
```

**Solutions**:

1. Check ImageRepository:
```bash
kubectl get imagerepository example-app -n example-app
```

2. Check ImagePolicy:
```bash
kubectl get imagepolicy example-app -n example-app
```

3. Verify registry credentials:
```bash
kubectl get secret registry-credentials -n flux-system -o yaml
```

4. Check image automation status:
```bash
flux get image update example-app -n example-app
```

5. Manually reconcile:
```bash
flux reconcile image update example-app -n example-app
```

---

## Performance Issues

### Slow Response Times

**Symptoms**:
```
P95 latency > 1s
Slow request handling
```

**Solutions**:

1. Check traces in Jaeger:
```
# Navigate to: http://localhost:16686
# Filter by slow operations
```

2. Check Prometheus metrics:
```promql
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))
```

3. Check CPU/Memory usage:
```bash
kubectl top pod <pod-name> -n example-app
```

4. Check resource limits:
```bash
kubectl get pod <pod-name> -n example-app -o jsonpath='{.spec.containers[0].resources}'
```

5. Increase resources:
```yaml
resources:
  limits:
    cpu: "1000m"  # Increased
    memory: "1Gi"
```

6. Profile with flamegraph:
```bash
cargo flamegraph
```

### High Memory Usage

**Symptoms**:
```
Pod using > 80% of memory limit
Frequent OOMKilled
```

**Solutions**:

1. Monitor memory usage:
```bash
kubectl top pod <pod-name> -n example-app
```

2. Check for memory leaks:
```bash
# Profile with flamegraph
cargo flamegraph --root --no-inline
```

3. Increase memory limit:
```yaml
resources:
  limits:
    memory: "2Gi"  # Increased
```

4. Optimize code:
- Use references instead of cloning
- Stream large data instead of loading into memory
- Use connection pooling

### Database Connection Pool Exhaustion

**Symptoms**:
```
Error: Redis connection pool exhausted
Error: Timeout acquiring connection
```

**Solutions**:

1. Check connection pool size:
```bash
# In config
cat config/production.toml | grep pool_size
```

2. Increase pool size:
```toml
[redis]
pool_size = 50  # Increased from 10
```

3. Check Redis max connections:
```bash
redis-cli -h <redis-host> -p 6379 CONFIG GET maxclients
```

4. Monitor active connections:
```bash
redis-cli -h <redis-host> -p 6379 CLIENT LIST | wc -l
```

---

## Debugging Techniques

### Enable Debug Logging

```bash
# Development
RUST_LOG=debug cargo run

# Kubernetes
kubectl set env deployment/example-app RUST_LOG=debug -n example-app

# Specific module
RUST_LOG=example_app_no_s3=debug,redis=trace cargo run
```

### Capture Request/Response

```bash
# Use verbose curl
curl -v http://localhost:8080/health/live

# Capture headers
curl -I http://localhost:8080/health/live

# Capture full request/response
curl -D - http://localhost:8080/health/live -o /dev/null
```

### View Full Stack Trace

```bash
# Enable backtrace
RUST_BACKTRACE=1 cargo test

# Full backtrace
RUST_BACKTRACE=full cargo run

# In Kubernetes
kubectl set env deployment/example-app RUST_BACKTRACE=1
```

### Port Forward for Debugging

```bash
# Forward local port to pod
kubectl port-forward <pod-name> 8080:8080 -n example-app

# Debug locally with tools
curl http://localhost:8080/health/live
```

### Exec into Pod

```bash
# Start shell in pod
kubectl exec -it <pod-name> -n example-app -- sh

# Check environment variables
env | grep APP

# Test connectivity
ping redis-0.redis.svc.cluster.local
```

### Check Network Connectivity

```bash
# Run debug pod
kubectl run debug --image=busybox --rm -it --restart=Never -- sh

# Test DNS
nslookup redis

# Test connectivity
nc -zv redis 6379

```

---

## Getting Help

### Before Asking for Help

1. Check logs:
```bash
kubectl logs deployment/example-app -n example-app
```

2. Describe resources:
```bash
kubectl describe ksvc example-app -n example-app
kubectl describe pod <pod-name> -n example-app
```

3. Check configuration:
```bash
kubectl get configmaps -n example-app
kubectl get secrets -n example-app
```

4. Search existing issues:
```
# GitHub Issues
https://github.com/your-org/example-app/issues

# Stack Overflow
https://stackoverflow.com/search?q=example-app
```

### Collecting Diagnostic Information

```bash
# Save to file
cat > diagnostic-info.txt <<EOF
# Version
kubectl version --client

# Cluster info
kubectl cluster-info

# Service status
kubectl get ksvc example-app -n example-app -o yaml

# Pod status
kubectl get pods -n example-app -l serving.knative.dev/service=example-app -o yaml

# Service logs
kubectl logs deployment/example-app -n example-app

# FluxCD status
flux get kustomizations -n example-app

# ConfigMaps
kubectl get configmaps -n example-app -o yaml

# Secrets (sanitized)
kubectl get secrets -n example-app -o yaml | grep -v password: | grep -v token:
EOF
```

### Support Channels

1. **Documentation**: Review all `docs/` directory
2. **GitHub Issues**: Create issue with diagnostic info
3. **Slack/Discord**: Ask in community channels
4. **Internal**: Contact team Slack/email

---

## Next Steps

- **Development**: See `docs/DEVELOPMENT.md`
- **Deployment**: See `docs/DEPLOYMENT.md`
- **Monitoring**: See `docs/MONITORING.md`
- **Security**: See `docs/SECURITY.md`
