# Upgrading Guide

Guide for upgrading example-app template and projects generated from it.

## Table of Contents

- [Template Versioning](#template-versioning)
- [Upgrading the Template](#upgrading-the-template)
- [Upgrading Generated Projects](#upgrading-generated-projects)
- [Breaking Changes](#breaking-changes)
- [Migration Guide](#migration-guide)

---

## Template Versioning

### Version Format

Template uses Semantic Versioning: `MAJOR.MINOR.PATCH`

- **MAJOR**: Breaking changes requiring manual migration
- **MINOR**: New features, backwards-compatible
- **PATCH**: Bug fixes, backwards-compatible

### Current Version

Check template version in `cargo-generate.toml`:
```toml
[template]
cargo_generate_version = ">=0.18.0"
```

### Finding Latest Version

```bash
# Check GitHub releases
gh release list --repo your-org/rust-knative-flux-template

# Or check git tags
git tag --list 'v*'
```

---

## Upgrading the Template

### For Template Maintainers

#### 1. Update Template Version

Edit `cargo-generate.toml`:
```toml
# Add version variable
[template]
version = "1.0.0"  # Update this
```

#### 2. Update CHANGELOG.md

```markdown
## [1.0.0] - 2024-01-15

### Added
- New feature X
- Update dependency Y

### Changed
- Modified behavior Z

### Fixed
- Bug fix A

### Breaking Changes
- Breaking change B (see migration guide)
```

#### 3. Update Documentation

- Update `README.md` if needed
- Update `docs/API.md` if API changed
- Update `docs/CONFIGURATION.md` if config changed

#### 4. Create Release

```bash
# Commit changes
git add .
git commit -m "chore: bump template to v1.0.0"

# Tag release
git tag -a v1.0.0 -m "Release v1.0.0"

# Push to GitHub
git push origin main
git push origin v1.0.0

# Create GitHub release
gh release create v1.0.0 \
  --title "Release v1.0.0" \
  --notes "See CHANGELOG.md for details"
```

---

## Upgrading Generated Projects

### Option 1: Re-generate from Latest Template (Recommended)

**When to use**:
- Major version changes
- Many breaking changes
- Early in project lifecycle

**Process**:
```bash
# Backup your project
cp -r my-service my-service.backup

# Generate new project
cargo generate --git https://github.com/your-org/rust-knative-flux-template \
  --name my-service-v2

# Copy your code changes to new project
# - src/handlers/ (your custom handlers)
# - config/*.toml (your config)
# - deploy/overlays/ (your environment configs)

# Update dependencies
cd my-service-v2
cargo build

# Run tests
cargo test

# Switch to new version
cd ..
mv my-service my-service-old
mv my-service-v2 my-service
```

### Option 2: Manual Migration

**When to use**:
- Minor/Patch version upgrades
- Few breaking changes
- Established project with many customizations

**Process**:

#### Step 1: Review Breaking Changes

Check `CHANGELOG.md` in template repository:
```bash
git clone https://github.com/your-org/rust-knative-flux-template.git
cd rust-knative-flux-template
cat docs/CHANGELOG.md
```

Look for:
- `### Breaking Changes`
- `### Deprecated`
- `### Removed`

#### Step 2: Update Dependencies

Edit `Cargo.toml`:
```toml
[dependencies]
# Update to new versions
axum = "0.7"
tokio = { version = "1.35", features = ["full"] }

# etc...
```

Update dependencies:
```bash
cargo update
```

#### Step 3: Update Configuration

**If configuration changed**, update config files:

**Old** (`config/development.toml`):
```toml
[s3]
endpoint = "http://minio:9000"
```

**New**:
```toml

```

#### Step 4: Update Code

**If API changed**, update your handlers:

**Old**:
```rust
pub async fn upload_handler(
    State(state): State<AppState>,
    body: String,
) -> impl IntoResponse {
    state.storage.write("file.txt", body.as_bytes()).await
}
```

**New**:
```rust
pub async fn upload_handler(
    State(state): State<AppState>,
    body: Bytes,  // Changed from String
) -> impl IntoResponse {
    state.storage.write("file.txt", body.to_vec()).await
}
```

#### Step 5: Update Kubernetes Manifests

**If deployment changed**, update manifests:

**Old** (`deploy/base/knative-service.yaml`):
```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: example-app
spec:
  template:
    spec:
      containers:
      - image: my-service:latest
        env:
        - name: APP__REDIS__URL
          value: "redis://redis:6379"
```

**New**:
```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: example-app
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/minScale: "5"  # New annotation
    spec:
      containers:
      - image: my-service:latest
        env:
        - name: APP__REDIS__URL
          value: "redis://redis:6379"

```

#### Step 6: Update Tests

**If testing changed**, update test files:

**Old**:
```rust
#[tokio::test]
async fn test_upload() {
    let response = client.post("/api/upload", body).await;
    assert_eq!(response.status(), 200);
}
```

**New**:
```rust
#[tokio::test]
async fn test_upload() {
    let response = client
        .post("/api/upload")
        .header("Content-Type", "application/json")  // New required
        .body(body)
        .await;
    assert_eq!(response.status(), 201);  // Changed status code
}
```

#### Step 7: Run Full Test Suite

```bash
# Format code
cargo fmt

# Run linting
cargo clippy -- -D warnings

# Run unit tests
cargo test

# Start services for integration tests
docker-compose up -d

# Run integration tests
cargo test --test '*' --ignored --nocapture

# Cleanup
docker-compose down -v
```

#### Step 8: Deploy to Staging

```bash
# Build and push image
docker build -t my-registry/my-service:v2.0 .
docker push my-registry/my-service:v2.0

# Deploy to staging
kubectl apply -k deploy/overlays/staging

# Verify deployment
kubectl get pods -n my-service-staging
kubectl logs deployment/my-service -n my-service-staging
```

#### Step 9: Test in Production

```bash
# Deploy to production
kubectl apply -k deploy/overlays/prod

# Monitor
kubectl get pods -n my-service-prod
kubectl logs deployment/my-service -n my-service-prod

# Verify functionality
curl https://my-service.example.com/health/live
```

---

## Breaking Changes

### Example Breaking Change: v1.0.0 → v2.0.0

**Summary**:
- Removed `/api/list` endpoint
- Added required `region` to S3 configuration
- Changed upload endpoint from POST `upload` to POST `/api/upload`
- Updated minimum Rust version from 1.75 to 1.92

**Migration Required**:
```bash
# 1. Update code using /api/list
# Find: GET /api/list
# Replace with: GET /api/objects

# 2. Update S3 config
# Add to config/[env].toml:
[s3]
region = "us-east-1"

# 3. Update upload endpoint calls
# Find: POST http://service/upload
# Replace with: POST http://service/api/upload
```

---

## Migration Guide

### From v0.x to v1.0.0

#### 1. Rust Toolchain

**Update Rust**:
```bash
rustup update stable
rustup default stable

# Verify version
rustc --version  # Should be 1.92+
```

#### 2. Dependencies

**Update Cargo.toml**:
```toml
[dependencies]
axum = "0.7"  # Upgraded from 0.6
tokio = { version = "1.35", features = ["full"] }

```

**Run**:
```bash
cargo update
cargo build
```

#### 3. Configuration

**Update `config/default.toml`**:
```toml
# Add new telemetry config
[telemetry]
sampler = "always"  # New field


```

#### 4. Code Changes

**Update handlers**:

**Old** (v0.x):
```rust
use axum::extract::State;

pub async fn handler(State(state): State<AppState>) {
    // ...
}
```

**New** (v1.0.0):
```rust
use axum::extract::State;

#[instrument]  // Add tracing
pub async fn handler(State(state): State<AppState>) {
    // ...
}
```

#### 5. Tests

**Update integration tests**:

**Old**:
```rust
#[tokio::test]
async fn test_endpoint() {
    let client = Client::new();
    let response = client.get("http://localhost:8080/health/live")
        .send()
        .await;
}
```

**New**:
```rust
#[tokio::test]
#[ignore]  # Ignored by default, run with --ignored
async fn test_endpoint() {
    let client = Client::new();
    let response = client.get("http://localhost:8080/health/live")
        .send()
        .await
        .expect("Request failed");
    
    assert_eq!(response.status(), 200);
}
```

---

## Rollback Plan

### If Upgrade Fails

**Immediate Rollback**:
```bash
# Rollback Kubernetes deployment
kubectl rollout undo deployment/my-service -n my-service-prod

# Verify rollback
kubectl get pods -n my-service-prod
kubectl logs deployment/my-service -n my-service-prod
```

**Git Rollback**:
```bash
# Create rollback branch
git checkout -b rollback-v1.0.0 v1.0.0

# Push and deploy
git push origin rollback-v1.0.0
kubectl apply -k deploy/overlays/prod
```

### Test Rollback

```bash
# Verify health
curl https://my-service.example.com/health/live
curl https://my-service.example.com/health/ready

# Run smoke tests
# ... test critical functionality ...
```

---

## Upgrading Checklist

Before upgrading:
- [ ] Review CHANGELOG.md for breaking changes
- [ ] Backup current working directory
- [ ] Create backup branch: `git checkout -b backup-v1.0.0`
- [ ] Commit all current work

During upgrade:
- [ ] Update Rust toolchain
- [ ] Update Cargo.toml dependencies
- [ ] Update configuration files
- [ ] Update code for breaking changes
- [ ] Update Kubernetes manifests
- [ ] Run `cargo update`
- [ ] Run `cargo build`
- [ ] Run `cargo test`
- [ ] Run integration tests

After upgrade:
- [ ] Deploy to staging
- [ ] Verify staging deployment
- [ ] Run smoke tests
- [ ] Monitor logs and metrics
- [ ] Deploy to production
- [ ] Verify production deployment
- [ ] Monitor for 24 hours
- [ ] Delete backup branch if stable

---

## Getting Help

### If Migration Fails

1. **Check logs**:
```bash
kubectl logs deployment/my-service -n my-service-prod
```

2. **Review migration guide**: See specific version migration section above
3. **Check GitHub issues**: Search for similar problems
4. **Create issue**: Include error logs, version numbers, and steps

### Requesting Help

When requesting help, include:

**Environment**:
```bash
rustc --version
cargo --version
kubectl version --client
docker --version
```

**Configuration**:
```bash
cat config/production.toml
# Sanitize secrets!
```

**Error Logs**:
```bash
kubectl logs deployment/my-service -n my-service-prod --tail=100
```

---

## Additional Resources

- **CHANGELOG**: See `docs/CHANGELOG.md` in template repository
- **Template Issues**: https://github.com/your-org/rust-knative-flux-template/issues
- **Migration Discussions**: Check GitHub Discussions
- **Contributing**: See `docs/CONTRIBUTING.md`
