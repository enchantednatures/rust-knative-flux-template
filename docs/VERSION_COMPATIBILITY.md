# Version Compatibility Matrix

This document tracks the compatibility requirements for all components used in the template and E2E tests.

## Current Versions (2026-01-07)

| Component | Version | Notes |
|-----------|---------|-------|
| **Kubernetes** | v1.32.0 | Required for Knative v1.20, stable on macOS |
| **Knative Serving** | v1.20.0 | Latest stable release |
| **Knative Eventing** | v1.20.0 | Latest stable release (if using Kafka source) |
| **FluxCD** | Latest | Installed via `flux install` command |
| **Kind** | v0.31.0+ | Local cluster for testing |
| **Kourier** | v1.20.0 | Knative ingress controller |
| **Redis** | Latest (Bitnami) | Infrastructure dependency |
| **MinIO** | Latest (Helm chart) | S3-compatible storage |
| **PostgreSQL (CloudNativePG)** | 16 (default) | Optional database |

## Kubernetes → Knative Compatibility

| Kubernetes Version | Compatible Knative Versions | Status |
|-------------------|---------------------------|--------|
| v1.35.x | ❌ Not recommended | Kubelet issues on macOS |
| v1.34.x | ⚠️ Limited testing | Use with caution |
| v1.33.x | ✅ v1.20 | Supported but not tested |
| **v1.32.x** | **✅ v1.20** | **Recommended** (used in E2E) |
| v1.31.x | ✅ v1.19 | Supported for older Knative |
| v1.30.x | ✅ v1.19 | Supported for older Knative |
| v1.29.x | ⚠️ v1.18 | End of support |

**Reference:** [Knative Serving Releases](https://github.com/knative/serving/releases)

## Knative Version Requirements

### Knative v1.20.0 (Current)

- **Minimum Kubernetes:** v1.32.0
- **Recommended Kubernetes:** v1.32.x, v1.33.x
- **Release Date:** December 2024
- **Support Status:** Active
- **Breaking Changes:** None from v1.19
- **Features:**
  - Enhanced autoscaling
  - Improved cold start performance
  - Better observability integration

### Knative v1.19.0 (Previous)

- **Minimum Kubernetes:** v1.30.0
- **Recommended Kubernetes:** v1.30.x, v1.31.x
- **Release Date:** October 2024
- **Support Status:** Maintenance

## FluxCD Compatibility

FluxCD is generally compatible with all Kubernetes versions v1.28+. The template uses:

- **source-controller** - For OCIRepository and GitRepository resources
- **kustomize-controller** - For Kustomization resources
- **image-reflector-controller** - For automated image updates (optional)
- **image-automation-controller** - For automated commits (optional)

## Kind Compatibility

### Recommended Kind Node Images

```yaml
# Kubernetes v1.32.0 (recommended)
image: kindest/node:v1.32.0@sha256:c48c62eac5da28cdadcf560d1d8616cfa6783b58f0d94cf63ad1bf49600cb027

# Kubernetes v1.33.0 (alternative)
image: kindest/node:v1.33.0@sha256:...

# DO NOT USE v1.35.0 - kubelet issues on macOS
```

## Helm Chart Versions

The E2E tests use the latest Helm charts from stable repositories:

| Chart | Repository | Notes |
|-------|------------|-------|
| **redis** | bitnami/redis | `--set auth.enabled=false` for testing |
| **minio** | minio/minio | `--set mode=standalone` for testing |
| **cloudnative-pg** | cloudnative-pg/cloudnative-pg | PostgreSQL operator |

## CI vs Local Environment

| Aspect | CI (GitHub Actions) | Local (E2E Script) |
|--------|--------------------|--------------------|
| **Kubernetes** | v1.35.0 (Kind default) | v1.32.0 (pinned) |
| **Knative** | v1.20.0 | v1.20.0 |
| **Runner OS** | ubuntu-latest | macOS/Linux |
| **Docker** | Pre-installed | Docker Desktop required |

**Note:** CI uses newer Kubernetes v1.35.0 because GitHub-hosted runners have different characteristics than local macOS environments. v1.35.0 works fine on Linux but has issues on macOS.

## Testing Against Multiple Versions

To test with different Kubernetes versions locally:

```bash
# Edit the script
vim scripts/test-template-e2e-local.sh

# Change the image line in the Kind cluster config:
image: kindest/node:v1.33.0@sha256:...
```

**Important:** Ensure the Kubernetes version is compatible with Knative v1.20.0 (requires v1.32+).

## Version Update Policy

### When to Update

- **Kubernetes:** Update when new stable minor version is released and tested with Knative
- **Knative:** Update when new minor version is released (every ~3 months)
- **FluxCD:** Keep up-to-date via `flux install` (automatically uses latest)
- **Helm Charts:** Update periodically, test before committing

### Update Process

1. Check [Knative release notes](https://github.com/knative/serving/releases) for Kubernetes requirements
2. Test locally with new versions using E2E script
3. Update both CI workflow and local script
4. Update this compatibility matrix
5. Test both scenarios (no-s3, with-s3)
6. Commit and create PR

## Known Issues

### Kubernetes v1.35.0 on macOS

**Issue:** Kubelet fails to start with timeout errors
**Status:** Known upstream issue
**Workaround:** Use v1.32.0 (implemented in E2E script)
**Reference:** [Kind Issue #3737](https://github.com/kubernetes-sigs/kind/issues/3737)

### Knative v1.20.0 with Kubernetes v1.30.x

**Issue:** Incompatible - minimum Kubernetes v1.32 required
**Status:** By design
**Workaround:** Upgrade to Kubernetes v1.32+ or use Knative v1.19

## Checking Your Environment

```bash
# Check Kubernetes version in Kind cluster
kubectl version --short

# Check Knative version
kubectl get namespace knative-serving -o yaml | grep serving.knative.dev/release

# Check FluxCD version
flux version

# Check all component versions
kubectl get deployments -n knative-serving -o wide
kubectl get deployments -n flux-system -o wide
```

## References

- [Knative Serving Releases](https://github.com/knative/serving/releases)
- [Knative Installation Guide](https://knative.dev/docs/install/)
- [Kind Node Images](https://hub.docker.com/r/kindest/node/tags)
- [FluxCD Installation](https://fluxcd.io/flux/installation/)
- [Kubernetes Release Notes](https://kubernetes.io/releases/)

## Contributing

When updating versions, please:

1. Update this document
2. Update `scripts/test-template-e2e-local.sh`
3. Update `.github/workflows/template-e2e-test.yaml` if needed
4. Test all scenarios locally
5. Document any breaking changes in PR description
