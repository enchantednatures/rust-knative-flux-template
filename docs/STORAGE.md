{% if feature_s3 %}
# S3/RustFS Integration Guide

This template includes optional S3-compatible storage support via Apache OpenDAL, preconfigured with RustFS for local development.

## Architecture

```
┌──────────────────┐
│   Application    │
│   (Rust/Axum)    │
└────────┬─────────┘
         │
         │ (opendal::Operator)
         ▼
┌──────────────────┐         ┌──────────────────────────────┐
│   OpenDAL        │────────▶│  RustFS (local Kind)         │
│   S3 Backend     │         │  Ceph RGW (chart-provisioned)│
└──────────────────┘         │  or external S3              │
                             └──────────────────────────────┘
```

The `AppState` contains a pre-configured `opendal::Operator` that handles all object storage operations.

In deployed environments the bucket and its credentials come from an
ObjectBucketClaim that the chart creates; the app reads them from a
provisioner-owned Secret and ConfigMap. Local Kind development falls back to the
bundled RustFS, which mimics the same contract. See
[Kubernetes Deployment](#kubernetes-deployment).

## Configuration

### Local Development (RustFS)

RustFS is provided in `docker-compose.yaml` for development:

```yaml
services:
  rustfs:
    image: rustfs/rustfs:1.0.1
    command: ["/data"]
    ports:
      - "9000:9000"   # S3 API
      - "9001:9001"   # Web Console
    environment:
      RUSTFS_ACCESS_KEY: rustfsadmin
      RUSTFS_SECRET_KEY: rustfsadmin
```

Start it with:
```bash
docker-compose up -d rustfs rustfs-init
```

This automatically:
1. Starts RustFS on http://localhost:9000
2. Creates the `data` bucket via the `rustfs-init` service (using the `rc` CLI)
3. Makes web console available at http://localhost:9001

> **Local development only.** The docker-compose flow uses the bundled `data`
> bucket and the `rustfsadmin` / `rustfsadmin` credentials above. Deployed
> environments never use these literals: the provisioner creates the
> `<project>-app-data` bucket, Secret and ConfigMap, and the app consumes those
> (see [Kubernetes Deployment](#kubernetes-deployment)).

### Configuration Priority

The S3Config follows the same priority as other configs:

1. **Environment variables** (highest priority):
   - `APP__S3__ENDPOINT`
   - `APP__S3__BUCKET`
   - `APP__S3__REGION`
   - `AWS_ACCESS_KEY_ID` (standard AWS env var)
   - `AWS_SECRET_ACCESS_KEY` (standard AWS env var)

2. **Config file** (`config/{env}.toml`):
   ```toml
   [s3]
   endpoint = "http://localhost:9000"
   bucket = "data"
   region = "us-east-1"
   ```

3. **Defaults** (`config/default.toml`):
   ```toml
   [s3]
   endpoint = "http://localhost:9000"
   bucket = "data"
   region = "us-east-1"
   ```

## Using the Storage Operator

The storage operator is available in `AppState`:

```rust
use axum::{
    extract::State,
    http::StatusCode,
    response::IntoResponse,
};
use {{ crate_name }}::state::AppState;

async fn upload_handler(
    State(state): State<AppState>,
) -> Result<impl IntoResponse, String> {
    // Write object
    state
        .storage
        .write("documents/file.txt", b"content".to_vec())
        .await
        .map_err(|e| format!("Upload failed: {}", e))?;
    
    Ok(StatusCode::CREATED)
}

async fn download_handler(
    State(state): State<AppState>,
) -> Result<Vec<u8>, String> {
    // Read object
    let data = state
        .storage
        .read("documents/file.txt")
        .await
        .map_err(|e| format!("Download failed: {}", e))?;
    
    Ok(data.to_vec())
}

async fn list_handler(
    State(state): State<AppState>,
) -> Result<Vec<String>, String> {
    // List objects
    let mut entries = Vec::new();
    let mut lister = state
        .storage
        .list("documents/")
        .await
        .map_err(|e| format!("List failed: {}", e))?;
    
    while let Some(entry) = lister.next().await {
        let entry = entry.map_err(|e| format!("Entry error: {}", e))?;
        entries.push(entry.path().to_string());
    }
    
    Ok(entries)
}

async fn stat_handler(
    State(state): State<AppState>,
) -> Result<u64, String> {
    // Get object metadata
    let meta = state
        .storage
        .stat("documents/file.txt")
        .await
        .map_err(|e| format!("Stat failed: {}", e))?;
    
    Ok(meta.content_length())
}

async fn delete_handler(
    State(state): State<AppState>,
) -> Result<StatusCode, String> {
    // Delete object
    state
        .storage
        .delete("documents/file.txt")
        .await
        .map_err(|e| format!("Delete failed: {}", e))?;
    
    Ok(StatusCode::NO_CONTENT)
}
```

## Testing

Integration tests are provided in `tests/storage_test.rs`:

```bash
# Start RustFS
docker-compose up -d rustfs rustfs-init

# Run tests
cargo test --test storage_test -- --ignored --nocapture

# Run all tests (including integration tests)
cargo test -- --ignored
```

Test operations covered:
- Write and read objects
- Get object metadata (stat)
- List objects with prefix
- Delete objects

## Infrastructure: Terraform (optional, self-managed store)

This Terraform module manages MinIO/RustFS buckets for teams that run their own
object store instead of the chart-provisioned Ceph bucket. It is not used by the
dev/staging/prod Ceph deployments, which get their buckets and credentials from
the ObjectBucketClaim.

```bash
cd terraform

# Create .tfvars (local development values; rustfsadmin is local-dev only)
cat > terraform.tfvars <<EOF
minio_endpoint   = "http://localhost:9000"
minio_access_key = "rustfsadmin"
minio_secret_key = "rustfsadmin"
minio_use_ssl    = false
EOF

# Initialize and apply
terraform init
terraform apply
```

The module creates:
- `data` bucket (for development)
- `data-staging` bucket (with versioning)
- `data-prod` bucket (with versioning)

If you go this route, point the app at the resulting endpoint and bucket with
the [override](#override-for-external-s3--tls) above, and name those buckets with
your project prefix to avoid collisions.

### Production RustFS (Kubernetes)

For production RustFS deployed on Kubernetes:

```bash
# Update tfvars for production
cat > terraform.tfvars <<EOF
minio_endpoint   = "https://rustfs.production.svc.cluster.local:9000"
minio_access_key = "PRODUCTION_KEY"
minio_secret_key = "PRODUCTION_SECRET"
minio_use_ssl    = true
EOF

terraform apply
```

### AWS S3

To use AWS S3 instead of RustFS:

```toml
# config/production.toml
[s3]
endpoint = "https://s3.amazonaws.com"
bucket = "your-bucket"
region = "us-east-1"
```

```bash
export APP__S3__ENDPOINT="https://s3.amazonaws.com"
export APP__S3__BUCKET="your-bucket"
export APP__S3__REGION="us-east-1"
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"

cargo run
```

## Kubernetes Deployment

### App storage from the provisioned claim

In dev/staging/prod the chart declares an ObjectBucketClaim named
`{{ project_name | replace: "_", "-" }}-app-data`. The cluster's bucket
provisioner (Rook/Ceph RGW) creates the bucket and publishes two objects in the
release namespace:

- **Secret** `{{ project_name | replace: "_", "-" }}-app-data` with keys
  `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`
- **ConfigMap** `{{ project_name | replace: "_", "-" }}-app-data` with keys
  `BUCKET_HOST`, `BUCKET_PORT` and `BUCKET_NAME`

The base HelmRelease wires the app to those objects, so you don't create S3
credentials yourself. Env var names are unchanged:

| Env var | Source |
| --- | --- |
| `AWS_ACCESS_KEY_ID` | Secret `...-app-data`, key `AWS_ACCESS_KEY_ID` |
| `AWS_SECRET_ACCESS_KEY` | Secret `...-app-data`, key `AWS_SECRET_ACCESS_KEY` |
| `BUCKET_HOST` | ConfigMap `...-app-data`, key `BUCKET_HOST` |
| `BUCKET_PORT` | ConfigMap `...-app-data`, key `BUCKET_PORT` |
| `APP__S3__ENDPOINT` | literal `http://$(BUCKET_HOST):$(BUCKET_PORT)`, expanded from the two entries above |
| `APP__S3__BUCKET` | ConfigMap `...-app-data`, key `BUCKET_NAME` |
| `APP__S3__REGION` | literal `us-east-1` |

`BUCKET_HOST` and `BUCKET_PORT` are declared as env entries *before*
`APP__S3__ENDPOINT`, because Kubernetes only expands `$(VAR)` references using
env entries that appear earlier in the list. Reordering them breaks the
endpoint.

The `{{ project_name | replace: "_", "-" }}-secrets` Secret now carries only the
`redis-url` key; the old `aws-access-key-id` / `aws-secret-access-key` keys are
gone. Create it with:

```bash
kubectl create secret generic {{ project_name | replace: "_", "-" }}-secrets \
  --from-literal=redis-url='redis://redis:6379' \
  -n {{ target_namespace }}
```

Or sync just that key with the ExternalSecrets Operator:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: {{ project_name | replace: "_", "-" }}-secrets
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
  target:
    name: {{ project_name | replace: "_", "-" }}-secrets
  data:
    - secretKey: redis-url
      remoteRef:
        key: /prod/{{ project_name }}/redis-url
```

### RustFS in Kubernetes

Deploy RustFS on Kubernetes for production:

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rustfs
  namespace: rustfs
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rustfs
  template:
    metadata:
      labels:
        app: rustfs
    spec:
      containers:
        - name: rustfs
          image: rustfs/rustfs:1.0.1
          args: ["/data"]
          ports:
            - name: api
              containerPort: 9000
            - name: console
              containerPort: 9001
          env:
            - name: RUSTFS_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: rustfs-secret
                  key: access-key
            - name: RUSTFS_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: rustfs-secret
                  key: secret-key
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          emptyDir: {}
EOF
```

### Override for external S3 / TLS

To point the app at a store that is not the chart-provisioned claim (plain S3, an
existing bucket, or a TLS-protected RGW endpoint), patch the app env entries per
environment. The env list lives under
`/spec/values/services//env` in the HelmRelease; the environment overlays
already patch it (see `deploy/overlays/<env>/kustomization.yaml`).

Replace the four claim-sourced entries with literals and a Secret you own:

```yaml
# deploy/overlays/<env>/kustomization.yaml (excerpt)
patches:
  - target:
      kind: HelmRelease
      name: {{ project_name | replace: "_", "-" }}
    patch: |-
      - op: replace
        path: /spec/values/services//env
        value:
          # ... keep the non-S3 base entries (server, redis, telemetry) ...
          - name: AWS_ACCESS_KEY_ID
            valueFrom:
              secretKeyRef:
                name: {{ project_name | replace: "_", "-" }}-external-s3
                key: AWS_ACCESS_KEY_ID
          - name: AWS_SECRET_ACCESS_KEY
            valueFrom:
              secretKeyRef:
                name: {{ project_name | replace: "_", "-" }}-external-s3
                key: AWS_SECRET_ACCESS_KEY
          - name: APP__S3__ENDPOINT
            value: "https://s3.example.com"   # use https:// for TLS clusters
          - name: APP__S3__BUCKET
            value: "your-bucket"
          - name: APP__S3__REGION
            value: "us-east-1"
```

Key points:

- Set `APP__S3__ENDPOINT` to a literal endpoint and include `https://` for
  TLS-protected stores. Set `APP__S3__BUCKET` to your bucket name.
- Point `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` at a Secret you manage,
  not the claim Secret.
- Drop the `BUCKET_HOST` / `BUCKET_PORT` entries and the `APP__S3__ENDPOINT`
  interpolation when you override; they only make sense against the claim
  ConfigMap.
- `<project>-secrets` keeps only `redis-url` for these overrides; don't stuff S3
  keys back into it under the old `aws-access-key-id` names.

> **Never Git-manage a Secret with the claim name.** The provisioner owns the
> `<project>-app-data` Secret and rewrites it on reconciliation. A Git-managed
> Secret that reuses that name (or the backup name `<project>-postgres-backups`)
> fights the provisioner and your credentials get overwritten. Put external
> credentials in a differently named Secret, such as
> `{{ project_name | replace: "_", "-" }}-external-s3`. The provisioner Secret
> is also plaintext, so it must never be committed or SOPS-managed.

## Troubleshooting

> The steps below target the local docker-compose / Kind RustFS (`rustfsadmin`
> credentials, `data` bucket). Deployed environments get their bucket and
> credentials from the ObjectBucketClaim; check the provisioner Secret/ConfigMap
> instead.

### Connection refused error

**Problem**: `Connection refused` when connecting to RustFS

**Solution**:
1. Verify RustFS is running: `docker ps | grep rustfs`
2. Check endpoint in config: should be `http://rustfs:9000` (Docker Compose) or `http://localhost:9000` (local)
3. Wait for RustFS to fully start: `docker logs rustfs`

### Invalid credentials

**Problem**: `InvalidAccessKeyId` or similar auth errors

**Solution**:
1. Verify credentials in environment:
   ```bash
   echo $AWS_ACCESS_KEY_ID
   echo $AWS_SECRET_ACCESS_KEY
   ```
2. Default credentials for RustFS (local development): `rustfsadmin / rustfsadmin`
3. Check RustFS console at http://localhost:9001

### Bucket not found

**Problem**: `NoSuchBucket` errors

**Solution**:
1. Verify bucket was created: `rc ls local/`
2. Manually create bucket:
   ```bash
   docker exec rustfs-init rc bucket create -p local/data
   ```
3. Or use Terraform to create buckets

### Tests timeout

**Problem**: Integration tests hang or timeout

**Solution**:
1. Ensure RustFS is healthy: `docker ps`
2. Check RustFS logs: `docker logs rustfs`
3. Increase test timeout in CI: `cargo test -- --test-threads=1`

## Monitoring

### RustFS Web Console (local development)

Access RustFS UI at http://localhost:9001:
- Username: `rustfsadmin`
- Password: `rustfsadmin`

View bucket usage, object count, and metrics.

### OpenDAL Tracing

OpenDAL operations are traced via OpenTelemetry:

```rust
use tracing::instrument;

#[instrument(skip(state))]
async fn my_storage_operation(state: &AppState) -> Result<()> {
    let data = state.storage.read("key").await?;
    Ok(())
}
```

Traces appear in Jaeger with operation details.

## Best Practices

1. **Use descriptive paths**: `documents/user-123/report.pdf` instead of `file123.pdf`
2. **Add retry logic**: OpenDAL supports retry policies via layers
3. **Enable versioning**: For production buckets (automatic via Terraform)
4. **Use environment-specific buckets**: the chart names them
   `<project>-app-data` (dev) or `<project>-app-data-<env>` (staging/prod), so
   names never collide across namespaces
5. **Monitor usage**: Set up bucket lifecycle policies for old objects
6. **Test locally**: Always test with RustFS locally before production

{% else %}
# S3/RustFS Integration (Not Enabled)

This template was generated without S3 storage support. To add it later:

1. Update `cargo-generate.toml` to include S3 option
2. Re-generate the template with `if feature_s3 = true`

Or manually:
1. Add `opendal` dependency to `Cargo.toml`
2. Add `S3Config` struct to `src/config.rs`
3. Add `storage: Operator` to `AppState` in `src/state.rs`
4. Initialize operator in `src/main.rs`

{% endif %}
