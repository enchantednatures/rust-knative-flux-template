# Local E2E Testing Guide

This guide explains how to run the template E2E tests locally for faster debugging and iteration. The local test script mirrors the CI workflow in `.github/workflows/template-e2e-test.yaml` but uses local caching to significantly speed up test runs.

## Why Run Locally?

- **⚡ Faster iteration**: No waiting for CI queue (save ~30 minutes per run)
- **💾 Better caching**: Docker layers, Helm charts, and Cargo dependencies cached locally
- **🔍 Easier debugging**: Full access to cluster state, logs, and resources
- **🧪 Test before push**: Validate changes before committing to avoid broken CI

## Prerequisites

Install the required dependencies:

```bash
# macOS (via Homebrew)
brew install docker kind kubectl helm kustomize fluxcd/tap/flux

# Rust (if not already installed)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# cargo-generate (installed automatically by script if missing)
cargo install cargo-generate --locked
```

Verify installations:
```bash
docker --version
kind --version
kubectl version --client
helm version
kustomize version
flux version
cargo --version
```

## Quick Start

Run all E2E scenarios (no-s3 and with-s3):

```bash
./scripts/test-template-e2e-local.sh
```

Run a specific scenario:

```bash
# Test without S3 features
./scripts/test-template-e2e-local.sh no-s3

# Test with S3 features
./scripts/test-template-e2e-local.sh with-s3
```

## What the Script Does

The local E2E script performs the same steps as CI:

1. **Dependency Check**: Verifies all required tools are installed
2. **Local Registry Setup**: Creates a local Docker registry for caching images
3. **Kind Cluster Creation**: Spins up a Kind cluster with local registry integration
4. **Template Generation**: Uses `cargo-generate` to create a test project
5. **Structure Validation**: Ensures all required files are present
6. **Docker Build**: Builds the application image with local caching
7. **Manifest Preparation**: Builds Kubernetes manifests with Kustomize
8. **OCI Artifact Push**: Pushes manifests as OCI artifacts to local registry
9. **Flux Installation**: Installs Flux controllers in the cluster
10. **Knative Installation**: Deploys Knative Serving v1.20.0
11. **Infrastructure Setup**: Installs Redis and MinIO (if S3 enabled)
12. **Application Deployment**: Deploys the app via Flux GitOps
13. **E2E Test Execution**: Runs health checks and API tests

## Test Scenarios

### no-s3 Scenario

Tests the minimal configuration without S3 storage:
- Health endpoints (liveness, readiness)
- Prometheus metrics
- Hello API endpoint
- Redis integration

### with-s3 Scenario

Tests with S3/MinIO storage enabled:
- All tests from no-s3 scenario
- S3 storage upload/download example endpoint

## Debugging Failed Tests

If a test fails, the cluster remains running for debugging. Use the kubeconfig path shown in the output:

```bash
# Export kubeconfig
export KUBECONFIG=/tmp/kind-kubeconfig-no-s3

# Check pod status
kubectl get pods -A

# View application logs
kubectl logs -l serving.knative.dev/service=rust-service --tail=100

# Check Flux resources
flux get all -A

# Describe the Knative service
kubectl describe ksvc/rust-service

# Check events
kubectl get events --sort-by='.lastTimestamp' | tail -20
```

### Common Issues

**1. Cluster Creation Fails**
```bash
# Check Docker is running
docker ps

# Clean up any existing clusters
kind delete cluster --name e2e-no-s3
kind delete cluster --name e2e-with-s3
```

**2. Image Build Fails**
```bash
# Check generated Dockerfile
cat ./generated/test-app-no-s3/Dockerfile

# Test build manually
cd ./generated/test-app-no-s3
docker build -t test .
```

**3. Knative Service Not Ready**
```bash
# Check pod logs
kubectl logs -l serving.knative.dev/service=rust-service

# Check pod events
kubectl describe pod -l serving.knative.dev/service=rust-service

# Check Knative controller logs
kubectl logs -n knative-serving deployment/controller
```

**4. Flux Reconciliation Fails**
```bash
# Check OCIRepository status
kubectl describe ocirepository/test-app-no-s3 -n flux-system

# Check Kustomization status
kubectl describe kustomization/test-app-no-s3 -n flux-system

# Check Flux logs
kubectl logs -n flux-system deployment/source-controller --tail=50
kubectl logs -n flux-system deployment/kustomize-controller --tail=50
```

## Performance Tips

### Leverage Caching

The script uses several caching strategies:

1. **Docker Layer Cache**: Keep your Docker daemon running between test runs
2. **Local Registry**: Images are cached in `localhost:5001`
3. **Cargo Cache**: `cargo-generate` and dependencies are cached locally
4. **Helm Chart Cache**: Charts are cached in `~/.cache/helm`

### Keep Cluster Running

To inspect the cluster after tests complete, set `KEEP_CLUSTER=true`:

```bash
KEEP_CLUSTER=true ./scripts/test-template-e2e-local.sh no-s3
```

This preserves the cluster for debugging. Clean up manually when done:

```bash
kind delete cluster --name e2e-no-s3
```

### Parallel Testing (Advanced)

Run both scenarios in parallel using separate terminals:

```bash
# Terminal 1
./scripts/test-template-e2e-local.sh no-s3

# Terminal 2
./scripts/test-template-e2e-local.sh with-s3
```

## Cleanup

Remove all E2E test artifacts:

```bash
./scripts/cleanup-e2e-local.sh
```

This removes:
- Kind clusters (`e2e-no-s3`, `e2e-with-s3`)
- Local registry container (`kind-registry-e2e`)
- Generated project directories
- Template values files
- Kubeconfig files

## CI vs Local Differences

| Aspect | CI (GitHub Actions) | Local Script |
|--------|---------------------|--------------|
| **Registry** | GHCR (`ghcr.io`) | Local (`localhost:5001`) |
| **Authentication** | GitHub token | No auth required |
| **Image Tags** | PR/run number based | Local timestamp based |
| **Caching** | GitHub cache (limited) | Full local cache |
| **Execution Time** | ~30 minutes | ~10-15 minutes (cached) |
| **Parallelism** | Matrix jobs (sequential max-parallel: 1) | Manual parallel in separate terminals |
| **Cleanup** | Automatic | Manual or via cleanup script |

## Integration with Development Workflow

### Before Creating a PR

Run E2E tests locally to catch issues early:

```bash
# Test both scenarios
./scripts/test-template-e2e-local.sh

# If passing, create PR
git add .
git commit -m "feat: add new feature"
git push origin feature-branch
```

### Debugging CI Failures

If CI fails but you can't reproduce locally:

1. Check CI logs for the failing step
2. Run the same scenario locally: `./scripts/test-template-e2e-local.sh <scenario>`
3. Keep the cluster running: `KEEP_CLUSTER=true ./scripts/test-template-e2e-local.sh <scenario>`
4. Inspect cluster state manually
5. Compare local behavior with CI logs

### Testing Template Changes

When modifying template files:

```bash
# Make changes to template files
vim Cargo.toml.liquid

# Test locally
./scripts/test-template-e2e-local.sh

# Clean up between iterations
./scripts/cleanup-e2e-local.sh
```

## Troubleshooting

### Port Conflicts

If port 5001 is already in use:

```bash
# Check what's using the port
lsof -i :5001

# Stop conflicting service or use a different port
docker stop kind-registry-e2e
```

### Disk Space Issues

E2E tests create multiple Docker images and volumes. Clean up periodically:

```bash
# Remove unused Docker resources
docker system prune -a

# Remove Kind clusters
kind delete cluster --name e2e-no-s3
kind delete cluster --name e2e-with-s3

# Full cleanup
./scripts/cleanup-e2e-local.sh
docker system prune -a -f
```

### Memory Pressure

Running both scenarios consumes ~4-6GB RAM. Close unnecessary applications or run one scenario at a time.

## Advanced Usage

### Custom Template Values

Test with custom template values by modifying the generated `template-values-*.toml` file:

```bash
# Run script once to generate template values
./scripts/test-template-e2e-local.sh no-s3

# Edit the generated values
vim template-values-no-s3.toml

# Re-run cargo generate manually
cargo generate --path . \
    --name "test-app-no-s3" \
    --template-values-file template-values-no-s3.toml \
    --allow-commands
```

### Testing Specific Knative Versions

Modify the script to test different Knative versions:

```bash
# Edit the script
vim scripts/test-template-e2e-local.sh

# Change KNATIVE_VERSION variable
KNATIVE_VERSION="knative-v1.21.0"
```

### Inspecting Generated Manifests

View the Kustomize-built manifests before deployment:

```bash
# Run test with KEEP_CLUSTER=true
KEEP_CLUSTER=true ./scripts/test-template-e2e-local.sh no-s3

# Inspect built manifests
cat ./generated/test-app-no-s3/manifests-built/all.yaml
```

## Getting Help

If you encounter issues:

1. **Check [E2E Troubleshooting Guide](E2E_TROUBLESHOOTING.md)** - Comprehensive troubleshooting for common issues
2. Check the [Prerequisites](#prerequisites) are installed correctly
3. Review [Common Issues](#common-issues) above
4. Run with verbose output: `bash -x ./scripts/test-template-e2e-local.sh`
5. Check CI logs for comparison: `.github/workflows/template-e2e-test.yaml`
6. Open an issue with:
   - Script output
   - Cluster logs (`kubectl get events -A`)
   - Docker version
   - OS version

## Related Documentation

- **[E2E Troubleshooting](E2E_TROUBLESHOOTING.md)** - Detailed troubleshooting guide
- **[Version Compatibility](VERSION_COMPATIBILITY.md)** - Kubernetes, Knative, and component versions
- [Main README](../README.md) - Template overview and quick start
- [Development Guide](DEVELOPMENT.md) - Local development workflow
- [CI/CD Guide](CICD.md) - GitHub Actions configuration
- [Template Variables](../cargo-generate.toml) - Template configuration
