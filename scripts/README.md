# Scripts Directory

This directory contains utility scripts for development and testing.

## 📁 Directory Structure

```
scripts/
├── test-template-e2e-local.sh    # Run E2E tests locally (mirrors CI)
├── cleanup-e2e-local.sh          # Clean up E2E test artifacts
├── validate-*.sh                 # Validation scripts for manifests
├── setup-github-runners.sh       # GitHub self-hosted runner setup
└── dev/                          # Development environment scripts
    ├── setup-kind.sh             # Create Kind cluster
    ├── install-knative.sh        # Install Knative Serving
    ├── deploy-infrastructure.sh  # Deploy Redis, MinIO, etc.
    ├── deploy-observability.sh   # Deploy Jaeger, Prometheus, OTel
    ├── build-and-deploy.sh       # Build and deploy application
    └── port-forward.sh           # Port forward all services
```

## 🚀 Quick Start

### Local E2E Testing (Recommended)

Run the full E2E test suite locally instead of waiting for CI:

```bash
# Run all scenarios
./scripts/test-template-e2e-local.sh

# Run specific scenario
./scripts/test-template-e2e-local.sh no-s3
./scripts/test-template-e2e-local.sh with-s3

# Clean up
./scripts/cleanup-e2e-local.sh
```

**Benefits:**
- 🚀 60-70% faster than CI (8-12 min vs 30 min)
- 💾 Uses local caching for speed
- 🐛 Easier debugging with direct cluster access
- ✅ Test before pushing to avoid CI failures

**Documentation:**
- [Local E2E Testing Guide](../docs/LOCAL_E2E_TESTING.md) - Complete guide
- [Troubleshooting](../docs/E2E_TROUBLESHOOTING.md) - Fix common issues
- [Quick Reference](../.github/workflows/LOCAL_TESTING_QUICK_REF.md) - Cheat sheet

### Development Environment

Use the Makefile for common development tasks:

```bash
# Start full dev environment (cluster + all services + app)
make dev-up

# View logs
make dev-logs

# Rebuild and redeploy after code changes
make dev-restart

# Stop everything
make dev-down
```

See the [main README](../README.md) for more Makefile targets.

## 📖 Script Documentation

### E2E Testing Scripts

#### `test-template-e2e-local.sh`

Runs end-to-end tests for template generation locally. Mirrors the CI workflow in `.github/workflows/template-e2e-test.yaml`.

**Usage:**
```bash
./scripts/test-template-e2e-local.sh [scenario]
```

**Scenarios:**
- `no-s3` - Test without S3 features
- `with-s3` - Test with S3/MinIO features
- `all` - Test both scenarios (default)

**Requirements:**
- Docker Desktop running
- kind, kubectl, helm, kustomize, flux, cargo installed

**What it does:**
1. Creates Kind cluster with local registry
2. Generates project from template
3. Builds Docker image
4. Installs Knative, Flux, infrastructure
5. Deploys application via GitOps
6. Runs health checks and API tests

**On failure:**
- Cluster stays running for debugging
- Shows kubeconfig path for kubectl access
- Displays debugging commands

#### `cleanup-e2e-local.sh`

Removes all E2E test artifacts:
- Kind clusters (e2e-no-s3, e2e-with-s3)
- Local registry container
- Generated project directories
- Temporary files

**Usage:**
```bash
./scripts/cleanup-e2e-local.sh
```

### Development Scripts

See the [dev/](dev/) subdirectory for development environment scripts.

#### `dev/setup-kind.sh`
Creates a Kind cluster with local registry for development.

#### `dev/install-knative.sh`
Installs Knative Serving v1.20.0 with Kourier ingress.

#### `dev/deploy-infrastructure.sh`
Deploys Redis, MinIO, Kafka (optional) infrastructure services.

#### `dev/deploy-observability.sh`
Deploys Jaeger, Prometheus, and OpenTelemetry collector.

#### `dev/build-and-deploy.sh`
Builds Docker image and deploys application to Kind cluster.

#### `dev/port-forward.sh`
Port forwards all services for local access:
- Application: http://localhost:8080
- Jaeger: http://localhost:16686
- Prometheus: http://localhost:9090
- MinIO Console: http://localhost:9001

### Validation Scripts

#### `validate-knative-service.sh`
Validates Knative Service YAML syntax and structure.

#### `validate-postgres-manifests.sh`
Validates PostgreSQL CloudNativePG manifests.

## 🐛 Troubleshooting

### Common Issues

**Docker not running:**
```bash
# macOS
# Open Docker Desktop from Applications

# Linux
sudo systemctl start docker
```

**Script not executable:**
```bash
chmod +x ./scripts/test-template-e2e-local.sh
```

**Port conflicts:**
```bash
# Check what's using port 5001
lsof -i :5001

# Stop conflicting service
docker stop kind-registry-e2e
```

**Out of disk space:**
```bash
docker system prune -a -f
./scripts/cleanup-e2e-local.sh
```

For detailed troubleshooting, see:
- **[E2E Troubleshooting Guide](../docs/E2E_TROUBLESHOOTING.md)** - Comprehensive guide
- **[Local E2E Testing Guide](../docs/LOCAL_E2E_TESTING.md)** - Usage and debugging

## 🤝 Contributing

When adding new scripts:

1. Make them executable: `chmod +x script.sh`
2. Add shebang: `#!/usr/bin/env bash`
3. Use `set -euo pipefail` for safety
4. Add usage documentation in comments
5. Update this README

## 📚 Related Documentation

- [Main README](../README.md) - Project overview
- [Local E2E Testing](../docs/LOCAL_E2E_TESTING.md) - Complete E2E testing guide
- [E2E Troubleshooting](../docs/E2E_TROUBLESHOOTING.md) - Fix common issues
- [Development Guide](../docs/DEVELOPMENT.md) - Local development workflow
- [Makefile](../Makefile) - Common development commands
