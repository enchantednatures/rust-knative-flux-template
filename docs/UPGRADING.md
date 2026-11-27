# Upgrading Guide

Guide for upgrading {{ project_name }} template and projects generated from it.

## Table of Contents

- [Template Versioning](#template-versioning)
- [Template Inputs Snapshot](#template-inputs-snapshot)
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

The template version is declared in `cargo-generate.toml`:

```toml
[template]
version = "1.0.0"                # template release (this repo)
cargo_generate_version = ">=0.23.0"   # minimum cargo-generate CLI
```

`version` is template metadata (cargo-generate ignores unknown keys), and is
bumped with each tagged release. `cargo_generate_version` is the minimum CLI
version the config schema requires.

The release version is mirrored in two additional places, kept in sync by
`scripts/check-template-values.sh` (run it in CI and before tagging):

- `TEMPLATE_VALUES_VERSION` in `post-generate.rhai` — recorded in every project's
  `.cargo-generate/values.toml` as the snapshot version;
- `service-template/cargo-generate.toml` — recorded in every service snapshot.

The post-generation hook (or `scripts/add-service.sh` for services) records that
version, so a project's `make template-update` uses `v<version>` as the
three-way merge base. Tag releases accordingly (the helper warns and degrades to
a two-way report when the tag is missing, e.g. for projects generated from an
unreleased branch).

### Generated project versions

A generated project starts at `0.1.0` in both `Cargo.toml` and
`deploy/chart/Chart.yaml`; those follow the *generated project's* release
cadence, which is independent of the template's `[template] version`. Bump them
with the project's first release, not when regenerating.

Generate non-interactively from a values file:

```bash
# Lean project (every feature off); see template-values.toml in the template repo
cargo generate --path <template> --name my-service \
  --template-values-file template-values.toml --silent --allow-commands

# All features; see ci/template-values-full.toml
cargo generate --path <template> --name my-service \
  --template-values-file ci/template-values-full.toml --silent --allow-commands
```

### Finding Latest Version

```bash
# Check GitHub releases
gh release list --repo enchantednatures/rust-knative-flux-template

# Or check git tags
git tag --list 'v*'
```

---

## Template Inputs Snapshot

Generation records every answer in `.cargo-generate/values.toml` (commit it):

```toml
[template]
version = "1.0.0"      # template release the project was rendered from
name = "my-service"    # the --name input (decides the crate name)

[values]
project_name = "my-service"
feature_postgres = true
# …every answered placeholder, including the conditional ones
```

The file is ordinary TOML and is read by `cargo generate --template-values-file`,
so a project can always be re-rendered non-interactively:

```bash
cargo generate --path <template> \
  --name "$(awk -F'"' '/^name = /{print $2}' .cargo-generate/values.toml)" \
  --template-values-file .cargo-generate/values.toml \
  --silent --allow-commands --destination /tmp/regenerated
```

`make template-update` does this for you and merges the result (see
[Option 1](#option-1-make-template-update-recommended)).

Notes:

- Editing a value changes **future** regenerations only; it does not modify the
  current project. Disabling a feature also does not delete files that were
  already generated — generate fresh for structural changes.
- Services added with `make add-service` record their own
  `services/<slug>/.cargo-generate/values.toml`, including the `--name` that
  decides the service crate name.
- No prompt asks for a secret, and the snapshot is committed. If you add a
  secret-bearing prompt to a fork, exclude its value from the snapshot.
- Projects generated before this feature have no snapshot; generate once from
  the template (or write the file by hand) to opt in.

---

## Upgrading the Template

### For Template Maintainers

#### 1. Update Template Version

Edit `cargo-generate.toml`:
```toml
[template]
version = "1.1.0"  # Update this and tag the release
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

### Option 1: `make template-update` (Recommended)

**When to use**: any template update — the helper three-way merges, so your
edits survive.

The helper re-renders the template twice with `.cargo-generate/values.toml`:

- **base**: the release recorded in the snapshot (`v<version>` tag)
- **theirs**: the ref you update to (default: the recorded `template_ref`)

and merges `base → theirs` into your checkout. Files you never touched are
replaced, files you changed are merged (or kept), and upstream deletions are
applied only when the file is unmodified locally.

```bash
git switch -c template-update          # work on a branch; the helper never commits
make template-update                   # preview: summary + nothing written
make template-update ARGS='--diff'     # preview with the per-file patch
make template-update APPLY=1           # merge into the working tree
```

Useful switches:

```bash
make template-update REF=v1.2.0        # update to a specific template ref
make template-update ROOT_ONLY=1       # skip services/<slug> updates
make template-update NAME=orders-api   # only services/orders-api
make template-update ARGS='--base-ref v1.0.0'   # override the merge base
```

Every service with a snapshot is updated too (`services/<slug>`), and its
recorded version advances so the next update starts from the right base.

**After applying**:

```bash
git diff                               # review; resolve '<<<<<<<' markers
cargo fmt --all
cargo test
kubectl kustomize deploy/overlays/dev  # manifests still render
```

If the template added a placeholder that has no default, the render fails with a
"missing default value" hint: add that key to `.cargo-generate/values.toml` and
re-run.

Requires `git` and `cargo-generate >= 0.23`. The script refuses to write over a
dirty worktree unless you pass `ARGS='--force'`, and it never commits.

### Option 2: Re-generate and diff by hand

**When to use**: you want to inspect a completely fresh render, or the merge
base tag is unavailable.

```bash
cargo generate --path <template> \
  --name "$(awk -F'"' '/^name = /{print $2}' .cargo-generate/values.toml)" \
  --template-values-file .cargo-generate/values.toml \
  --silent --allow-commands --destination /tmp/regenerated

diff -ruN --exclude=.git --exclude=target /tmp/regenerated/my-service .
```

Copy over the files you want to take, or use `git merge-file` per file with the
previous release's render as the base.

### Option 3: Manual Migration

**When to use**:
- Major version changes
- Many breaking changes
- Established project with many customizations

**Process**:

#### Step 1: Review Breaking Changes

Check `CHANGELOG.md` in template repository:
```bash
git clone https://github.com/your-org/rust-knative-flux-template.git
cd rust-knative-flux-template
cat CHANGELOG.md
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
{% if feature_s3 %}opendal = "0.45"
{% endif %}
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
endpoint = "http://rustfs:9000"
```

**New**:
```toml
{% if feature_s3 %}[s3]
endpoint = "http://rustfs:9000"
region = "us-east-1"  # New required field
{% endif %}
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

**If deployment changed**, update manifests.

**HelmRelease `services` key (projects generated before the ksvc 0.6.6 bump)**:

Earlier template revisions used an empty-string key (`services.""`) for the app. The ksvc chart now rejects an empty `sink`, and `kafka.sources.*.sink` must reference a non-empty `services` key, so the app moved to a named `services.app` key with `nameOverride: ""` (which keeps the Knative Service name equal to `fullnameOverride`).

**Old** (`deploy/base/helmrelease.yaml`):
```yaml
services:
  "":
    scaling:
      minScale: 1
      maxScale: 10
```

**New**:
```yaml
services:
  app:
    nameOverride: ""
    scaling:
      minScale: 5  # New value
      maxScale: 10
```

If the project uses a Kafka source, point its sink at the new key in the same HelmRelease:
```yaml
kafka:
  sources:
    <topic>:
      sink: "app"
```

Every overlay patch that targets the old key must change with it: replace `services.""` with `services.app` and add `nameOverride: ""` under it in `deploy/overlays/*/kustomization.yaml`. Then re-render to confirm the overlays still build:
```bash
kubectl kustomize deploy/overlays/dev
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
make local-up

# Run integration tests
cargo test -- --ignored --nocapture

# Cleanup
make local-down
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
{% if feature_s3 %}
opendal = "0.45"  # Upgraded from 0.40
{% endif %}
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

{% if feature_s3 %}# Add S3 region
[s3]
region = "us-east-1"  # New required field
{% endif %}
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
- [ ] Create a branch: `git switch -c template-update`
- [ ] Commit all current work (the helper refuses a dirty worktree)
- [ ] Snapshot exists: `.cargo-generate/values.toml`

During upgrade:
- [ ] `make template-update` — review the preview
- [ ] `make template-update APPLY=1` — merge
- [ ] Resolve any `<<<<<<<` conflict markers
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

- **CHANGELOG**: See `CHANGELOG.md` in template repository
- **Template Issues**: https://github.com/your-org/rust-knative-flux-template/issues
- **Migration Discussions**: Check GitHub Discussions
- **Contributing**: See `docs/CONTRIBUTING.md`
