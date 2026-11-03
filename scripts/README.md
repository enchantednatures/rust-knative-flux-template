# Scripts Directory

Utility scripts for local development, bootstrapping, and manifest validation.

## Directory Structure

```
scripts/
├── bootstrap-git-auth.sh         # Create the Flux SSH deploy-key Secret
├── setup-github-runners.sh       # Register the ARC runner scale set secrets
├── validate-postgres-manifests.sh # Validate CloudNativePG manifests
└── dev/                          # Local Kind lifecycle
    ├── setup-kind.sh             # Create the Kind cluster + local registry
    ├── install-knative.sh        # Install Knative Serving + Kourier
    ├── install-knative-eventing.sh # Install Eventing core (PingSource)
    ├── install-knative-kafka.sh  # Install Knative Kafka controller
    ├── deploy-infrastructure.sh  # Deploy Redis, RustFS, Kafka
    ├── deploy-observability.sh   # Deploy Jaeger, Prometheus, OTel
    ├── deploy-postgres.sh        # Deploy the CNPG cluster
    ├── build-and-deploy.sh       # Build the image and deploy the Knative service
    └── port-forward.sh           # Port-forward every service
```

## Quick Start

Use the Makefile for the normal workflow; the scripts are the implementation.

```bash
# Start the full environment (cluster + infrastructure + app)
make local-up

# Application logs, status, redeploy
make dev-logs
make dev-status
make dev-restart

# Tear down
make local-down
```

See the [main README](../README.md) for every Makefile target and
[docs/DEVELOPMENT.md](../docs/DEVELOPMENT.md) for the workflow.

## Script Documentation

### Bootstrap

#### `bootstrap-git-auth.sh`

Creates the `flux-system` SSH deploy-key Secret used by the Flux
`GitRepository` for private repositories. Invoked by `make git-auth`.

#### `setup-github-runners.sh`

Creates the `github-auth-secret` the ARC runner scale set needs. Only relevant
when the project was generated with `feature_gha_runner`.

### Development Scripts

#### `dev/setup-kind.sh`
Creates a Kind cluster with a local registry on `localhost:5001`.

#### `dev/install-knative.sh`
Installs Knative Serving v1.20.0 with the Kourier ingress.

#### `dev/install-knative-eventing.sh`
Installs Knative Eventing core and the PingSource CRD (needed by
`feature_cron`). Requires cluster-admin.

#### `dev/install-knative-kafka.sh`
Installs the Knative Kafka controller and broker (needed by
`event_source_kafka` / `feature_kafka`).

#### `dev/deploy-infrastructure.sh`
Deploys Redis, RustFS, and (when enabled) Kafka, then creates the RustFS
buckets and the claim-named Secret/ConfigMap.

#### `dev/deploy-observability.sh`
Deploys Jaeger, Prometheus, and the OpenTelemetry collector.

#### `dev/deploy-postgres.sh`
Deploys the CloudNativePG operator resources and the PostgreSQL cluster.

#### `dev/build-and-deploy.sh`
Builds the Docker image, pushes it to the local registry, renders the chart
with the dev overlay values, and applies the Knative service.

#### `dev/port-forward.sh`
Port-forwards every service for local access:

- Application: http://localhost:8080
- Jaeger: http://localhost:16686
- Prometheus: http://localhost:9090
- RustFS console: http://localhost:9001

### Validation

#### `validate-postgres-manifests.sh`
Validates the CloudNativePG manifests (Cluster, ObjectStore, ScheduledBackup)
and the per-environment patches. Run by CI for every `feature_postgres` row.

## E2E Testing

There is no local E2E runner any more; the suites that used to live in
`scripts/` drifted out of sync with the manifests and were removed. End-to-end
coverage runs in CI:

- `.github/workflows/template-generate-and-validate.yaml` — generation matrix,
  lint, build, release build, overlay/chart render, and the live-infra
  integration suites.
- `.github/workflows/template-e2e-test.yaml` — Kind + Knative deploy per
  scenario with health/event/storage assertions.

## Troubleshooting

**Docker not running:**
```bash
# Linux
sudo systemctl start docker
# macOS: start Docker Desktop
```

**Script not executable:**
```bash
chmod +x ./scripts/dev/*.sh
```

**Port conflicts:**
```bash
lsof -i :5001        # local registry
docker stop kind-registry-dev
```

**Out of disk space:**
```bash
docker system prune -a -f
make local-down
```

## Contributing

When adding a new script:

1. Make it executable: `chmod +x script.sh`
2. Add a shebang: `#!/usr/bin/env bash`
3. Use `set -euo pipefail`
4. Add usage documentation in comments
5. Update this README and expose it through a Makefile target

## Related Documentation

- [Main README](../README.md)
- [Development Guide](../docs/DEVELOPMENT.md)
- [Testing Guide](../docs/TESTING.md)
- [Makefile](../Makefile)
