# Configuration Guide

Complete reference for configuring test-app, including environment variables, configuration files, and secrets management.

## Configuration Hierarchy

The application loads configuration in this priority order (highest to lowest):

1. **Environment Variables** - Override everything
2. **Environment-Specific Config** - `config/{APP_ENV}.toml` (default: `development`)
3. **Default Config** - `config/default.toml`
4. **Compile-Time Defaults** - Hard-coded values in code

This hierarchy allows:
- Local development with `development.toml`
- Production secrets via environment variables
- Team overrides via shared config files
- Safe defaults for all settings

### Priority Example

If you set:
```bash
export APP__SERVER__PORT=9000
```

Then port 9000 will be used regardless of what's in config files.

---

## Environment Variables

Environment variables use the format `APP__SECTION__KEY=value` and override corresponding config file settings.

### Server Configuration

```bash
# Server bind address (default: 0.0.0.0)
export APP__SERVER__HOST=0.0.0.0

# Server port (default: 8080)
export APP__SERVER__PORT=8080

# Worker threads for Tokio runtime
export TOKIO_WORKER_THREADS=4
```

### Redis Configuration

```bash
# Redis connection URL (default: redis://localhost:6379)
export APP__REDIS__URL=redis://localhost:6379

# Redis connection timeout (default: 5s)
export APP__REDIS__TIMEOUT_SECS=5

# Redis pool size (default: 10)
export APP__REDIS__POOL_SIZE=10
```



### Telemetry Configuration

```bash
# OpenTelemetry collector endpoint
# Local: http://localhost:4317 (gRPC OTLP)
# Kubernetes: http://opentelemetry-collector:4317
export APP__TELEMETRY__OTLP_ENDPOINT=http://localhost:4317

# Service name for traces and metrics
export APP__TELEMETRY__SERVICE_NAME=test-app

# Log level (trace, debug, info, warn, error)
export APP__TELEMETRY__LOG_LEVEL=info

# Tracing sampler
# 'always' = trace all requests
# 'never' = trace nothing
# 'ratio:0.1' = trace 10% of requests
export APP__TELEMETRY__SAMPLER=always

# Structured logging format (json or text)
export APP__TELEMETRY__LOG_FORMAT=json

# Rust logging filter (overrides APP__TELEMETRY__LOG_LEVEL)
export RUST_LOG=info,test_app_no_s3=debug
```

### Application Configuration

```bash
# Environment name (used to select config file)
# - development (selects config/development.toml)
# - staging (selects config/staging.toml)
# - production (selects config/production.toml)
export APP_ENV=development

# Graceful shutdown timeout (default: 30s)
export APP__SHUTDOWN__TIMEOUT_SECS=30
```

---

## Configuration Files

Configuration files use TOML format. They're organized by section.

### Default Configuration (`config/default.toml`)

```toml
[server]
host = "0.0.0.0"
port = 8080

[redis]
url = "redis://localhost:6379"
timeout_secs = 5
pool_size = 10

[telemetry]
otlp_endpoint = "http://localhost:4317"
service_name = "test-app"
log_level = "info"
sampler = "always"
log_format = "json"

[shutdown]
timeout_secs = 30
```

### Development Configuration (`config/development.toml`)

Override default settings for development:

```toml
[server]
# Listen on localhost only for development
host = "127.0.0.1"
port = 8080

[telemetry]
# Enable debug logging in development
log_level = "debug"

# Log locally, not to collector
# (optional: use RUST_LOG env var instead)
```

### Staging Configuration (`config/staging.toml`)

```toml
[server]
# Listen on all interfaces
host = "0.0.0.0"
port = 8080

[redis]
# Use managed Redis in staging
url = "redis://redis-staging.example.com:6379"

[telemetry]
log_level = "info"

# Use staging collector
otlp_endpoint = "http://opentelemetry-collector-staging:4317"
```

### Production Configuration (`config/production.toml`)

```toml
[server]
host = "0.0.0.0"
port = 8080

[redis]
# Managed Redis cluster
url = "redis://redis-prod-cluster.example.com:6379"
pool_size = 50  # Higher concurrency in production

[telemetry]
log_level = "warn"  # Only warnings and errors in production
otlp_endpoint = "http://opentelemetry-collector:4317"

[shutdown]
# Longer graceful shutdown for production
timeout_secs = 60
```

---

## Loading Configuration

### Local Development

```bash
# Uses config/development.toml + config/default.toml
cargo run

# With debug logging
RUST_LOG=debug cargo run

# Override specific setting
APP__SERVER__PORT=9000 cargo run
```

### Kubernetes Deployment

Configuration is managed via ConfigMaps and Secrets:

```bash
# Create ConfigMap from config file
kubectl create configmap test-app-config \
  --from-file=config/production.toml

# Create Secret for sensitive values
kubectl create secret generic test-app-secrets \
  --from-literal=redis-url='redis://redis:6379' \
  
```

Then inject into Pod via environment variables:

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: test-app
spec:
  template:
    spec:
      containers:
       - image: localhost:5001/test-org/test-app:latest
        env:
        - name: APP__SERVER__PORT
          value: "8080"
        - name: APP__REDIS__URL
          valueFrom:
            secretKeyRef:
              name: test-app-secrets
              key: redis-url
        
```

---

## Secrets Management

Never commit secrets to Git. Use one of these approaches:

### Option 1: Environment Variables (Kubernetes)

Inject secrets via environment variables in the Pod spec:

```yaml
env:
- name: AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: my-secrets
      key: aws-access-key-id
```

### Option 2: Kubernetes Secrets

Create Secrets and mount as environment variables:

```bash
kubectl create secret generic test-app-secrets \
  --from-literal=redis-url='redis://...' \
  
```

### Option 3: External Secrets Operator (Recommended)

Sync secrets from external secret management (AWS Secrets Manager, HashiCorp Vault):

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: test-app-secrets
spec:
  # Sync every hour
  refreshInterval: 1h
  
  # Reference to the secret store
  secretStoreRef:
    name: aws-secrets-manager
    kind: SecretStore
  
  # Target Kubernetes Secret
  target:
    name: test-app-secrets
    creationPolicy: Owner
  
  # Secrets to sync from AWS
  data:
  - secretKey: redis-url
    remoteRef:
      key: /test-app/production/redis-url
  
```

### Option 4: Sealed Secrets (GitOps)

Encrypt secrets in Git using Sealed Secrets:

```bash
# Encrypt a secret
echo -n "my-password" | kubectl create secret generic my-secret \
  --dry-run=client \
  --from-file=/dev/stdin \
  -o yaml | kubeseal > my-secret.sealed.yaml

# Commit to Git
git add my-secret.sealed.yaml

# Deploy - Sealed Secrets controller decrypts automatically
kubectl apply -f my-secret.sealed.yaml
```

---

## Environment-Specific Setup

### Development

1. **Start services**:
   ```bash
   make dev-up
   ```

2. **Run app** (uses `config/development.toml`):
   ```bash
   cargo run
   ```

3. **Environment**: Automatically selected based on `APP_ENV=development`

### Staging

1. **Build and push image**:
   ```bash
    docker build -t localhost:5001/test-org/test-app:v1.0 .
    docker push localhost:5001/test-org/test-app:v1.0
   ```

2. **Deploy with Kustomize** (uses `config/staging.toml`):
   ```bash
   kubectl apply -k deploy/overlays/staging
   ```

3. **Create secrets** before deployment:
   ```bash
   kubectl create secret generic test-app-secrets \
     --from-literal=redis-url='redis://redis-staging:6379' \
     -n staging
   ```

### Production

1. **Same build process as staging**

2. **Deploy via FluxCD** (GitOps):
   ```bash
   flux create source git test-app \
     --url=https://github.com/your-org/test-app \
     --branch=main
   
   flux create kustomization test-app \
     --source=GitRepository/test-app \
     --path=deploy/overlays/prod \
     --prune=true \
     --interval=30s
   ```

3. **Create secrets from External Secrets**:
   ```bash
   kubectl apply -f deploy/secrets/external-secret.yaml
   ```

---

## Configuration Validation

The application validates configuration on startup:

```bash
# Valid configuration
$ cargo run
2024-01-15T10:30:45.123Z  INFO test_app_no_s3: Loading configuration
2024-01-15T10:30:45.124Z  INFO test_app_no_s3: Config loaded: server.host=0.0.0.0, server.port=8080
2024-01-15T10:30:45.125Z  INFO test_app_no_s3: Connecting to Redis...
2024-01-15T10:30:45.200Z  INFO test_app_no_s3: Connected to Redis
2024-01-15T10:30:45.201Z  INFO test_app_no_s3: Server listening on 0.0.0.0:8080

# Invalid configuration
$ APP__SERVER__PORT=invalid cargo run
Error: Failed to parse configuration
Reason: port must be a number between 1-65535, got: invalid

# Missing required setting
$ APP__REDIS__URL= cargo run
Error: Failed to parse configuration
Reason: redis.url is required but not set
```

---

## Dynamic Configuration

Currently, configuration is **immutable** after startup. To change settings:

1. Update config file or environment variable
2. Restart the application
3. New configuration takes effect

Future versions may support:
- Hot-reloading (watch config files for changes)
- Feature flags (enable/disable features without restart)
- A/B testing (route % of traffic to experimental config)

---

## Debugging Configuration

### Check What Configuration Was Loaded

```bash
RUST_LOG=debug cargo run 2>&1 | grep -i config
```

Output shows:
- Which config files were loaded
- Which environment variables were used
- Final resolved configuration

### Override Specific Settings

```bash
# Override just the port
APP__SERVER__PORT=9000 cargo run

# Override multiple settings
APP__SERVER__PORT=9000 \
  APP__REDIS__URL=redis://prod-redis:6379 \
  cargo run

# Override log level
RUST_LOG=debug cargo run
```

### Verify Secrets Are Set

```bash
# Check if environment variable is set (careful: may expose secret!)
echo $AWS_ACCESS_KEY_ID

# Safer: just check if it's defined
[ -z "$AWS_ACCESS_KEY_ID" ] && echo "Not set" || echo "Set"

# In Kubernetes
kubectl exec -it deployment/test-app -- printenv | grep AWS
```

---

## Best Practices

1. **Use environment variables for secrets**: Never commit credentials to Git
2. **Use config files for non-sensitive settings**: Makes it easy to see defaults
3. **Keep config files small**: Only override what differs from defaults
4. **Document configuration**: Add comments in config files explaining options
5. **Test configuration**: Validate config before deploying to production
6. **Rotate secrets regularly**: Use External Secrets Operator for automatic rotation
7. **Use strong defaults**: Default to secure values (e.g., `log_level=warn` in production)
8. **Per-environment secrets**: Different secrets for dev/staging/prod

---

## Common Configuration Mistakes

### Mistake 1: Hardcoded Secrets

❌ Bad:
```toml
[s3]
access_key_id = "AKIAIOSFODNN7EXAMPLE"
```

✅ Good:
```bash
export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
```

### Mistake 2: Wrong Redis URL

❌ Bad:
```toml
[redis]
url = "localhost:6379"  # Missing redis:// scheme
```

✅ Good:
```toml
[redis]
url = "redis://localhost:6379"
```

### Mistake 3: S3 Endpoint for Wrong Provider

❌ Bad (MinIO local with AWS S3 endpoint):
```bash
export APP__S3__ENDPOINT=https://s3.amazonaws.com
export APP__S3__PATH_STYLE=false
```

✅ Good:
```bash
export APP__S3__ENDPOINT=http://localhost:9000
export APP__S3__PATH_STYLE=true
```

### Mistake 4: Wrong Environment Selected

❌ Running with wrong config:
```bash
# Defaults to development.toml
cargo run
```

✅ Explicitly set environment:
```bash
APP_ENV=production cargo run
```

---

## Next Steps

- **Secrets**: See `docs/SECURITY.md` for secret management best practices
- **Deployment**: See `docs/DEPLOYMENT.md` for Kubernetes-specific configuration
- **Troubleshooting**: See `docs/TROUBLESHOOTING.md` for configuration issues
