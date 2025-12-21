# Template Configuration Guide

This is a `cargo-generate` template. It supports conditional features that are applied during project generation.

## Template Structure

All files with `.liquid` extension are template files using Shopify Liquid syntax. They are automatically renamed (`.liquid` removed) during generation.

### Liquid Variables

The template supports these variables:

| Variable | Source | Example |
|----------|--------|---------|
| `{{ project_name }}` | User prompt | `my-awesome-service` |
| `{{ crate_name }}` | Auto-derived | `my_awesome_service` |
| `{{ include_s3 }}` | User prompt | `true` or `false` |

### Liquid Filters

Available filters for transformations:

```liquid
{{ project_name | kebab_case }}       # my-awesome-service
{{ project_name | snake_case }}       # my_awesome_service
{{ project_name | upper_camel_case }} # MyAwesomeService
{{ project_name | title_case }}       # My Awesome Service
{{ crate_name | replace(from="-", to="_") }}  # my_awesome_service
```

## Generation Flow

When you run:

```bash
cargo generate --git https://github.com/your-org/rust-knative-flux-template
```

Cargo-generate:

1. **Prompts for values**:
   - `project_name`: Your project name
   - `include_s3`: Whether to include S3 support

2. **Processes template files**:
   - Evaluates all `*.liquid` files with your values
   - Renames files (removes `.liquid` extension)
   - Removes conditionally excluded content

3. **Non-liquid files** are copied as-is:
   - `Dockerfile`
   - `Cargo.lock`
   - Source files without `.liquid` suffix
   - Kubernetes configs that aren't conditional

## Conditional Content

Use Liquid `if` tags to conditionally include content:

```liquid
{% if include_s3 %}
# This section only appears if S3 is enabled
[dependencies]
opendal = "0.55"
{% endif %}
```

Example in Cargo.toml.liquid:

```toml
[dependencies]
redis = "0.24"

{% if include_s3 %}
opendal = { version = "0.55", features = ["services-s3"] }
{% endif %}
```

If `include_s3 = false`: opendal dependency is omitted
If `include_s3 = true`: opendal dependency is included

## Template Files Breakdown

### Core Application (Always Included)

- `src/main.rs.liquid` - Entry point with Redis initialization
- `src/lib.rs.liquid` - Module exports
- `src/config.rs.liquid` - Configuration structs
- `src/state.rs.liquid` - AppState (Redis only, or +Storage)
- `src/routes.rs` - Router setup (static)
- `src/handlers/*` - HTTP handlers (static)
- `src/error.rs` - Error types (static)
- `src/observability.rs` - Telemetry setup (static)

### Configuration (Conditional)

- `config/default.toml.liquid` - Default settings
- `config/development.toml.liquid` - Dev overrides
- Both include `[s3]` section only if `include_s3 = true`

### Docker (Conditional)

- `docker-compose.yaml.liquid` - Local dev services
  - Always includes: Redis, Jaeger, Prometheus, OpenTelemetry
  - Conditional (S3): MinIO service and initialization

### Kubernetes (Conditional)

- `deploy/base/knative-service.yaml.liquid`
  - Base Knative Service definition
  - Conditional S3 env vars injected

- `deploy/base/secret.yaml.example.liquid`
  - Secret template with AWS credentials if S3 enabled

- `deploy/overlays/dev/kustomization.yaml.liquid`
- `deploy/overlays/staging/kustomization.yaml.liquid`
- `deploy/overlays/prod/kustomization.yaml.liquid`
  - Environment patches
  - Conditional ConfigMap for S3 settings

- `deploy/flux/` - Static FluxCD configs (not conditional)

### Infrastructure (Conditional)

- `terraform/main.tf.liquid`
  - Root module with MinIO module call (if S3 enabled)

- `terraform/variables.tf.liquid`
  - S3 provider variables (if S3 enabled)

- `terraform/modules/minio/main.tf` - MinIO resource definitions
- `terraform/modules/minio/outputs.tf` - Output bucket names

### Testing (Conditional)

- `tests/storage_test.rs.liquid`
  - S3 integration test stubs (if S3 enabled)
  - Tests: write/read, stat, list, delete

- `tests/common/mod.rs` - Common test utilities (static)
- `tests/health_test.rs` - Health check tests (static)

### CI/CD (Conditional)

- `.github/workflows/ci.yaml.liquid`
  - GitHub Actions workflow
  - Conditional MinIO service in test job (if S3 enabled)

### Documentation (Conditional)

- `README.md.liquid` - Main documentation
  - S3/MinIO section included if enabled

- `STORAGE.md.liquid` - S3/MinIO detailed guide
  - Full content if S3 enabled
  - Notice only if S3 disabled

- `GETTING_STARTED.md` - Static quick start guide

### Package Metadata

- `Cargo.toml.liquid`
  - Project name: `{{ crate_name }}`
  - Optional dependencies based on `include_s3`

## Example Generations

### Without S3

```bash
cargo generate --git https://github.com/your-org/rust-knative-flux-template
? Project name: my-service
? Include S3-compatible storage? n
```

Result:
- Redis connection only in AppState
- No OpenDAL dependency
- No MinIO in docker-compose
- No Terraform S3 config
- `STORAGE.md` shows notice (not enabled)
- CI doesn't run S3 integration tests

### With S3

```bash
cargo generate --git https://github.com/your-org/rust-knative-flux-template
? Project name: my-service
? Include S3-compatible storage? y
```

Result:
- AppState includes both Redis and Storage (Operator)
- OpenDAL dependency added to Cargo.toml
- MinIO service in docker-compose
- Terraform module for bucket management
- `STORAGE.md` with full S3 integration guide
- CI runs S3 integration tests
- All S3 credentials in Kubernetes secrets

## Adding New Options

To add a new conditional feature:

1. **Update `cargo-generate.toml`**:
   ```toml
   [placeholders]
   my_feature = { prompt = "Enable feature?", type = "bool", default = false }
   ```

2. **Use in template files**:
   ```liquid
   {% if my_feature %}
   # Content only if feature enabled
   {% endif %}
   ```

3. **Files to update**:
   - `Cargo.toml.liquid` - Add conditional dependency
   - `src/config.rs.liquid` - Add config struct
   - `src/state.rs.liquid` - Add to AppState if needed
   - `docker-compose.yaml.liquid` - Add service if needed
   - Any Kubernetes manifests (liquid)
   - Test files if applicable
   - Documentation files

## Development Tips

### Testing the Template Locally

Before publishing:

```bash
# Generate from local template
cargo generate --path /path/to/rust-knative-flux-template --name test-project

# Test with S3
cargo generate --path /path/to/rust-knative-flux-template \
  --name test-project-s3 \
  --define include_s3=true

# Verify generated project
cd test-project
cargo build
cargo test
docker-compose up -d
cargo run
```

### Testing Liquid Syntax

Use the cargo-generate substitution:

```bash
# Dry run (show what would be generated)
cargo generate --path . --name test --dry-run
```

### Common Liquid Issues

**Issue**: `undefined variable` error
- Solution: Check variable name in prompt matches template usage
- Ensure exact spelling (case-sensitive)

**Issue**: Conditional content not removed
- Solution: Use `{% if %}` / `{% endif %}` pair, not inline
- Test with `--dry-run`

**Issue**: File not being templated
- Solution: Files must end with `.liquid` to be templated
- Static files are copied as-is

## Publishing

When ready to publish:

1. **Verify all templates work**:
   ```bash
   cargo generate --path . --name test-no-s3
   cargo generate --path . --name test-with-s3 --define include_s3=true
   ```

2. **Test generated projects**:
   ```bash
   cd test-no-s3 && cargo test && cargo build
   cd ../test-with-s3 && cargo test && cargo build
   ```

3. **Push to GitHub**:
   ```bash
   git push origin main
   ```

4. **Users can now generate**:
   ```bash
   cargo generate --git https://github.com/your-org/rust-knative-flux-template
   ```

## References

- [cargo-generate docs](https://cargo-generate.github.io/cargo-generate/)
- [Liquid template language](https://shopify.github.io/liquid/)
- [Shopify Liquid filters](https://shopify.dev/api/liquid/filters)
