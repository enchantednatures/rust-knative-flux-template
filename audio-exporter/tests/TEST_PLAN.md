# E2E Testing Strategy

## Overview

This document describes the end-to-end testing approach for the cargo-generate template. The testing system validates that:

1. Template generation produces correct output
2. Generated projects build and run correctly
3. Knative services deploy and function properly
4. CloudEvents are processed correctly
5. S3 storage operations work (when enabled)

## Architecture

### Dynamic Test Generation

The CI/CD pipeline generates test projects on-the-fly using `cargo generate` for two scenarios:

- **no-s3** - Generated with `if features contains "s3"=false` (basic service only)
- **with-s3** - Generated with `if features contains "s3"=true` (includes S3/MinIO support)

This approach ensures:
- Tests always validate the latest template code
- No stale reference implementations in the repository
- CI mirrors the actual user experience of using the template

### Test Flow

```
1. Template Generation
    ├─ Run cargo-generate for both scenarios
    └─ Validate generated project structure

2. Image Build
    ├─ Build Docker image for each scenario
    ├─ Push to GHCR
    └─ Load into Kind cluster

3. Manifest Processing
    ├─ Build manifests with kustomize
    ├─ Push as OCI artifact
    └─ Verify OCI artifact integrity

4. Cluster Setup
    ├─ Create Kind cluster (fast K8s in Docker)
    ├─ Install Knative Serving (minimal install)
    ├─ Install Flux CD (source + kustomize controllers)
    └─ Deploy infrastructure (Redis + optional MinIO)

5. Deployment via Flux
    ├─ Create OCIRepository resource
    ├─ Create Kustomization resource
    └─ Wait for Flux reconciliation

6. Testing
    ├─ Health checks (liveness, readiness)
    ├─ API endpoints (hello, swagger)
    ├─ Metrics (Prometheus format)
    └─ S3 operations (if if features contains "s3"=true)

7. Cleanup
    └─ Destroy Kind cluster
```

## CI Workflow

The E2E tests are run via GitHub Actions workflow in `.github/workflows/template-e2e-test.yaml`.

### Matrix Strategy

```yaml
matrix:
  include:
    - scenario: no-s3
      if features contains "s3": "false"
    - scenario: with-s3
      if features contains "s3": "true"
```

### Key Checkpoints

Each E2E test run validates multiple checkpoints:

1. **Template Generation**: Validates `cargo generate` produces expected structure
2. **Image Build**: Validates Docker image builds successfully and is pushed to GHCR
3. **OCI Artifact**: Validates manifests can be pushed and pulled as OCI artifacts
4. **Cluster Dependencies**: Validates Flux, Knative, Redis, and MinIO are healthy
5. **Application Deployment**: Validates the application is deployed via Flux
6. **E2E Tests**: Validates all application endpoints work correctly

## Test Scenarios

### no-s3 Scenario

Tests the basic service functionality:
- Liveness and readiness probes
- Hello API endpoint
- Prometheus metrics endpoint

### with-s3 Scenario

Tests full service functionality including S3 storage:
- All no-s3 tests
- S3/MinIO storage operations (write and read)

## Cluster Resources

The E2E tests deploy the following infrastructure:

### Core Services
- **Flux CD**: Source controller + Kustomize controller
- **Knative Serving**: Serving core + Kourier ingress
- **Redis**: Used for session/cache storage

### Optional (with-s3 only)
- **MinIO**: S3-compatible object storage for testing storage operations

## Running Tests Locally

### Prerequisites

```bash
# Install required tools
kind --version
kubectl version --client
helm version
flux version
cargo install cargo-generate
```

### Manual Test Execution

You can reproduce the CI workflow locally:

```bash
# 1. Generate a test project
cargo generate --path . \
  --name test-local \
  --define if features contains "s3"=true \
  --define project_name=test-app \
  --define target_namespace=default \
  --define github_org=your-org \
  --define github_repo=your-repo \
  --define default_branch=main \
  --define enable_image_updates=false \
  -o ./generated

# 2. Build and validate
cd generated/test-local
docker build -t test-local:latest .
cargo check
cargo test

# 3. Deploy to cluster
# Follow DEPLOYMENT.md steps
```

## Test Result Interpretation

### Successful Test Flow

```
✅ All tests PASSED for scenario: with-s3
======================================
Checkpoint 1: Template generation valid
Checkpoint 2: Application image verified in GHCR
Checkpoint 3: OCI artifact verified
Checkpoint 4: All cluster dependencies healthy
Checkpoint 5: Application deployed and ready
Checkpoint 6: Final validation summary
```

### Common Failures

#### Template Generation Issues
- **Symptom**: Missing required files during checkpoint 1
- **Cause**: Template files modified incorrectly
- **Solution**: Review template structure and file references

#### Image Build Issues
- **Symptom**: Docker build fails during checkpoint 2
- **Cause**: Dockerfile incompatibility or missing dependencies
- **Solution**: Review Dockerfile.liquid template

#### Flux Reconciliation Issues
- **Symptom**: OCIRepository or Kustomization fails during checkpoint 5
- **Cause**: Invalid manifests or OCI artifact issues
- **Solution**: Review kustomize build output and OCI artifact structure

#### Application Runtime Issues
- **Symptom**: Health checks or API tests fail
- **Cause**: Application logic errors or missing environment variables
- **Solution**: Check application logs and secret configuration

## Troubleshooting

### Inspecting Test Artifacts

The CI workflow provides debug information on failure:

```bash
# Flux logs
kubectl logs -n flux-system deployment/source-controller --tail=100
kubectl logs -n flux-system deployment/kustomize-controller --tail=100

# Application logs
kubectl logs -l serving.knative.dev/service=rust-service --tail=100

# All pods
kubectl get pods -A -o wide

# Recent events
kubectl get events -A --sort-by='.lastTimestamp' | tail -50
```

### Common Issues

1. **Port conflicts**: Ensure Kind cluster is deleted before starting new test
2. **Resource constraints**: Increase Kind cluster memory if pods fail to start
3. **Image pull errors**: Verify GHCR authentication and permissions
4. **Manifest validation**: Use `kubectl apply --dry-run=client` to validate locally

## Test Maintenance

### When to update tests

Update the E2E test workflow when:
- Adding new application features
- Changing template structure
- Updating dependencies (Knative, Flux, etc.)
- Modifying deployment manifests

### Test Data

Cloudevents test fixtures are located in `tests/e2e/fixtures/cloudevents/`:
- `simple-event.json` - Basic CloudEvent
- `data-event.json` - CloudEvent with data payload

## Performance Characteristics

- **Total test time**: ~30 minutes per scenario
- **Parallel execution**: Up to 2 scenarios (max-parallel: 1 for resource safety)
- **Cluster setup**: ~5 minutes
- **Image build**: ~3-5 minutes
- **Deployment**: ~5 minutes
- **Tests**: ~1 minute

## Security Considerations

The E2E tests use GitHub's built-in secrets for authentication:
- `GITHUB_TOKEN` - Used for GHCR authentication
- No external secrets required
- All resources are created in ephemeral Kind cluster

## References

- **Workflow**: `.github/workflows/template-e2e-test.yaml`
- **Template config**: `cargo-generate.toml`
- **Test fixtures**: `tests/e2e/fixtures/`
- **Deployment docs**: `DEPLOYMENT.md`
- **Architecture docs**: `ARCHITECTURE.md`
