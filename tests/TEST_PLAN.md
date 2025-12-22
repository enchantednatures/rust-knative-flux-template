# E2E Testing Strategy

## Overview

This document describes the end-to-end testing approach for the cargo-generate template. The testing system validates that:

1. Template generation produces correct output (verified against reference implementations)
2. Generated projects build and run correctly
3. Knative services deploy and function properly
4. CloudEvents are processed correctly
5. S3 storage operations work (when enabled)

## Architecture

### Reference Implementation Pattern

The repository maintains fully-generated reference implementations in `examples/`:

- **`examples/with-s3/`** - Generated with `include_s3=true` (includes S3/MinIO support)
- **`examples/no-s3/`** - Generated with `include_s3=false` (basic service only)

These serve dual purposes:
1. **Living documentation** - Users can browse working, fully-generated code
2. **Test baseline** - CI verifies `cargo generate` produces identical output

### Test Flow

```
1. Template Verification
   ├─ Run cargo-generate for both scenarios
   ├─ Diff against examples/
   └─ FAIL if mismatch (examples out of sync)

2. Cluster Setup
   ├─ Create Kind cluster (fast K8s in Docker)
   ├─ Install Knative Serving (minimal install)
   ├─ Install Flux CD (source + kustomize controllers)
   └─ Deploy infrastructure (Redis + optional MinIO)

3. Deployment
   ├─ Build Docker image from examples/
   ├─ Load into Kind cluster
   └─ Deploy via kubectl (simulates Flux sync)

4. Testing
   ├─ Health checks (liveness, readiness)
   ├─ API endpoints (hello, swagger)
   ├─ CloudEvents (simple + complex payloads)
   ├─ Metrics (Prometheus format)
   └─ S3 operations (if include_s3=true)
```

## File Structure

```
tests/
  e2e/
    scripts/
      00-setup-kind.sh              # Create Kind cluster
      01-install-knative.sh         # Install Knative Serving
      02-install-flux.sh            # Install Flux CD
      03-deploy-infrastructure.sh   # Deploy Redis + MinIO
      04-verify-generation.sh       # Verify cargo-generate output
      05-deploy-reference.sh        # Build and deploy examples/
      06-run-tests.sh               # Run test suite
      99-cleanup.sh                 # Cleanup resources
    
    fixtures/
      cloudevents/
        simple-event.json           # CloudEvent test data
        data-event.json             # CloudEvent with complex payload
    
    kind-config.yaml                # Kind cluster configuration
    TEST_PLAN.md                    # This file
  
examples/
  with-s3/                          # Full generated reference
    src/
    deploy/
    Cargo.toml
    Dockerfile
    README.md
    ...
  
  no-s3/                            # Full generated reference
    src/
    deploy/
    Cargo.toml
    Dockerfile
    README.md
    ...

.github/workflows/
  template-e2e-test.yaml            # GitHub Actions workflow
```

## Running Tests Locally

### Prerequisites

```bash
# Install required tools
brew install kind kubectl  # or apt-get on Linux

# Install Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Install Flux CLI
curl -s https://fluxcd.io/install.sh | bash

# Install cargo-generate
cargo install cargo-generate
```

### Generate Reference Implementations (One-time)

Before running tests, generate the reference implementations and commit them:

```bash
cd /path/to/rust-knative-flux-template

# Generate both scenarios
cargo generate --path . --name with-s3 --define include_s3=true
cargo generate --path . --name no-s3 --define include_s3=false

# Move to examples directory
rm -rf examples
mkdir examples
mv with-s3 examples/
mv no-s3 examples/

# Remove Cargo.lock (we ignore these in diffs)
rm examples/*/Cargo.lock

# Verify they compile
cd examples/with-s3 && cargo check
cd ../no-s3 && cargo check

# Commit
git add examples/
git commit -m "Add reference implementations for E2E testing"
```

Alternatively, run the helper script:
```bash
scripts/generate-examples.sh
```

### Run Full E2E Test Suite

```bash
cd /path/to/rust-knative-flux-template

# Test both scenarios sequentially
for scenario in no-s3 with-s3; do
  include_s3=$([ "$scenario" = "with-s3" ] && echo "true" || echo "false")
  
  echo "=== Testing $scenario scenario ==="
  
  # Setup
  tests/e2e/scripts/00-setup-kind.sh "$scenario"
  tests/e2e/scripts/01-install-knative.sh
  tests/e2e/scripts/02-install-flux.sh
  tests/e2e/scripts/03-deploy-infrastructure.sh "$include_s3"
  
  # Verify generation and deploy
  tests/e2e/scripts/04-verify-generation.sh "$scenario" "$include_s3"
  tests/e2e/scripts/05-deploy-reference.sh "$scenario" "$include_s3"
  
  # Test
  tests/e2e/scripts/06-run-tests.sh "$scenario" "$include_s3"
  
  # Cleanup
  tests/e2e/scripts/99-cleanup.sh "$scenario"
done
```

### Test Individual Scenario

For faster iteration during development:

```bash
SCENARIO="with-s3"
INCLUDE_S3="true"

# Setup (if not already done)
tests/e2e/scripts/00-setup-kind.sh "$SCENARIO"
tests/e2e/scripts/01-install-knative.sh
tests/e2e/scripts/02-install-flux.sh
tests/e2e/scripts/03-deploy-infrastructure.sh "$INCLUDE_S3"

# Deploy and test
tests/e2e/scripts/05-deploy-reference.sh "$SCENARIO" "$INCLUDE_S3"
tests/e2e/scripts/06-run-tests.sh "$SCENARIO" "$INCLUDE_S3"

# Don't cleanup - reuse cluster for next test iteration
```

### Test Template Verification Only

Quickly test if `cargo generate` matches reference implementations:

```bash
tests/e2e/scripts/04-verify-generation.sh with-s3 true
tests/e2e/scripts/04-verify-generation.sh no-s3 false
```

## Test Coverage

### Scenario: no-s3 (Basic Service)

Verifies the template without S3/MinIO support:

- ✅ Template generation (verify opendal NOT included)
- ✅ Docker build succeeds
- ✅ Knative Service deployment succeeds
- ✅ Health endpoints respond (liveness, readiness)
- ✅ API endpoints work (hello endpoint)
- ✅ CloudEvents accepted (simple and complex payloads)
- ✅ Metrics endpoint (Prometheus format)
- ✅ Redis connectivity verified
- ✅ Swagger UI accessible
- ✅ No panics in pod logs

### Scenario: with-s3 (Full-featured Service)

All of `no-s3` tests plus:

- ✅ Template generation (verify opendal IS included)
- ✅ MinIO deployment succeeds
- ✅ S3 storage endpoint operational
  - Writes JSON to S3
  - Reads it back
  - Verifies integrity
  - Auto-cleanup test files
- ✅ S3 response structure validated

## Updating Reference Implementations

When template files are modified, regenerate and commit the examples:

```bash
# Regenerate both scenarios
rm -rf examples/
cargo generate --path . --name with-s3 --define include_s3=true
cargo generate --path . --name no-s3 --define include_s3=false

# Move to examples
mkdir examples
mv with-s3 examples/
mv no-s3 examples/

# Cleanup Cargo.lock
rm examples/*/Cargo.lock

# Verify compilation
cd examples/with-s3 && cargo check
cd ../no-s3 && cargo check

# Test the update
../tests/e2e/scripts/00-setup-kind.sh with-s3
../tests/e2e/scripts/01-install-knative.sh
../tests/e2e/scripts/02-install-flux.sh
../tests/e2e/scripts/03-deploy-infrastructure.sh true
../tests/e2e/scripts/05-deploy-reference.sh with-s3 true
../tests/e2e/scripts/06-run-tests.sh with-s3 true

# Cleanup and commit
cd ../..
tests/e2e/scripts/99-cleanup.sh with-s3
git add examples/
git commit -m "Update reference implementations after template changes"
```

## Troubleshooting

### Template verification fails

```
ERROR: Generated template differs from reference implementation!
```

**Cause:** Template changes without updating examples/

**Solution:** Regenerate examples (see "Updating Reference Implementations" above)

### Kind cluster won't start

```bash
# List clusters
kind get clusters

# Delete stuck cluster
kind delete cluster --name e2e-with-s3

# Retry
tests/e2e/scripts/00-setup-kind.sh with-s3
```

### Knative Service stuck pending

```bash
# Check pod status and events
kubectl get pods -n test-app
kubectl describe pod -n test-app

# Check Knative revision
kubectl get revision -n test-app
kubectl describe revision <name> -n test-app

# View detailed logs
kubectl logs -n test-app -l serving.knative.dev/service=rust-service --all-containers=true -f
```

### Pods crashing

```bash
# Check logs for errors
kubectl logs -n test-app -l serving.knative.dev/service=rust-service --previous

# Check resource availability
kubectl describe nodes

# Check environment variables and secrets
kubectl describe pod -n test-app <pod-name>
```

### MinIO tests fail

```bash
# Verify MinIO is running
kubectl get pods -n services -l app=minio
kubectl get svc -n services

# Check MinIO logs
kubectl logs -n services -l app=minio

# Verify bucket exists and is accessible
kubectl run minio-check --rm -i --image=minio/mc --restart=Never -- \
  sh -c "mc alias set local http://minio.services.svc.cluster.local:9000 minioadmin minioadmin && mc ls local"

# Verify connectivity from pod
kubectl exec -n test-app <pod-name> -- \
  curl -v http://minio.services.svc.cluster.local:9000/minio/health/live
```

### Redis connectivity issues

```bash
# Check Redis pod
kubectl get pods -n services -l app=redis
kubectl logs -n services -l app=redis

# Test from pod
kubectl exec -n test-app <pod-name> -- redis-cli -h redis.services -p 6379 ping
```

### Service URL not working

```bash
# Get the actual URL
kubectl get ksvc rust-service -n test-app

# Check Kourier is properly routing
kubectl get svc -n kourier-system
kubectl logs -n kourier-system -l app=3scale-kourier-gateway --tail=50

# Test with curl including Host header
curl -H "Host: rust-service.test-app.127.0.0.1.sslip.io" http://localhost:8080/health/live
```

### Flux controller issues

```bash
# Check Flux status
flux get all -A

# Check controller logs
kubectl logs -n flux-system -l app=source-controller
kubectl logs -n flux-system -l app=kustomize-controller

# Manually reconcile
flux reconcile source git rust-service -n flux-system
flux reconcile kustomization rust-service -n flux-system
```

## CI/CD Integration

The workflow `.github/workflows/template-e2e-test.yaml` runs on:

- Push to `main`
- Pull requests to `main`
- Manual dispatch (`workflow_dispatch`)

### Matrix Strategy

Runs 2 parallel jobs:
- `e2e-no-s3` - Tests basic scenario (no S3 support)
- `e2e-with-s3` - Tests S3-enabled scenario

### Performance

Typical job duration:
- Template verification: ~30s
- Kind cluster setup: ~2m
- Knative Serving install: ~2m
- Flux install: ~1m
- Infrastructure deployment: ~1m
- Docker build: ~2-3m
- Application deployment: ~1-2m
- Tests execution: ~1m
- **Total:** ~12-15 minutes per scenario

### Caching

Cargo dependencies are cached between runs to speed up:
- Template generation
- Docker builds
- Example verification

## Adding New Tests

### Add HTTP endpoint test

Edit `tests/e2e/scripts/06-run-tests.sh`:

```bash
run_test "Your test name" \
  "curl -f -s '${SERVICE_URL}/api/v1/your/endpoint' | jq -e '.expected_field' > /dev/null" || ((FAILED++))
```

### Add conditional test (S3-only)

```bash
if [ "$INCLUDE_S3" = "true" ]; then
  run_test "S3-specific test" \
    "curl -f -s -X POST '${SERVICE_URL}/api/v1/storage/example' | jq '.success'" || ((FAILED++))
fi
```

### Add new CloudEvent fixture

1. Create JSON file: `tests/e2e/fixtures/cloudevents/your-event.json`
2. Add test in `06-run-tests.sh`:

```bash
run_test "Your CloudEvent test" \
  "curl -f -s -X POST '${SERVICE_URL}/' \
    -H 'Content-Type: application/json' \
    -H 'Ce-Specversion: 1.0' \
    -H 'Ce-Type: your.type' \
    -H 'Ce-Source: e2e-tests' \
    -H 'Ce-Id: test-xyz' \
    -d @tests/e2e/fixtures/cloudevents/your-event.json > /dev/null" || ((FAILED++))
```

## Maintenance

### When to regenerate examples

Regenerate `examples/` when:
- ✏️ Template files (*.liquid) are modified
- ✏️ Cargo.toml.liquid dependencies change
- ✏️ Kubernetes manifests change
- ✏️ Dockerfile or build configuration changes

### Keeping in sync

The CI workflow `04-verify-generation.sh` prevents drift:
- Fails if generated code differs from `examples/`
- Forces deliberate, reviewed updates
- Can be run locally before committing

### Version updates

When updating versions:
1. Update in template files (*.liquid)
2. Regenerate examples
3. Test locally
4. Commit both template and examples together

## Performance Tips

### Local testing

Skip S3 tests during early development:
```bash
# Test just no-s3 scenario (faster)
tests/e2e/scripts/00-setup-kind.sh no-s3
tests/e2e/scripts/01-install-knative.sh
tests/e2e/scripts/02-install-flux.sh
tests/e2e/scripts/03-deploy-infrastructure.sh false
tests/e2e/scripts/05-deploy-reference.sh no-s3 false
tests/e2e/scripts/06-run-tests.sh no-s3 false
```

### Reuse cluster

Don't cleanup between tests on the same scenario:
```bash
# Setup once
tests/e2e/scripts/00-setup-kind.sh with-s3
tests/e2e/scripts/01-install-knative.sh
tests/e2e/scripts/02-install-flux.sh
tests/e2e/scripts/03-deploy-infrastructure.sh true

# Run tests multiple times
tests/e2e/scripts/05-deploy-reference.sh with-s3 true
tests/e2e/scripts/06-run-tests.sh with-s3 true

# Modify code, rebuild, test again
tests/e2e/scripts/05-deploy-reference.sh with-s3 true
tests/e2e/scripts/06-run-tests.sh with-s3 true

# Cleanup once done
tests/e2e/scripts/99-cleanup.sh with-s3
```

## Future Enhancements

Potential improvements to the E2E testing:

- [ ] Load testing with simulated traffic
- [ ] Chaos engineering tests (pod failures, network partitions)
- [ ] Performance benchmarking
- [ ] Security scanning of generated artifacts
- [ ] Integration with real CI/CD (deploy to staging environment)
- [ ] Knative Eventing tests (event sourcing)
- [ ] Multi-region deployment tests
- [ ] Database/persistence layer tests
