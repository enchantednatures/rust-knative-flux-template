# Quickstart: CI/CD Workflows and k6 Load Testing

**Feature**: 009-ci-workflows-k6  
**Date**: 2026-02-01

## Prerequisites

- Git repository generated from this template
- Kubernetes cluster with:
  - Knative Serving installed
  - FluxCD installed and configured
  - Prometheus deployed (in observability namespace)
- GitHub repository with:
  - Actions enabled
  - Packages (ghcr.io) access enabled

## Quick Start (5 minutes)

### 1. Generate Repository from Template

```bash
# Clone or use GitHub "Use this template" button
gh repo create my-service --template enchantednatures/rust-knative-flux-template --private
cd my-service
```

### 2. Verify Workflows Exist

```bash
ls -la .github/workflows/
# Expected:
# - build.yaml      # Build and push to ghcr.io
# - test.yaml       # Run tests on PRs
# - deploy.yaml     # GitOps deployment
# - load-test.yaml  # k6 load testing
```

### 3. Push Initial Code

```bash
git add .
git commit -m "Initial commit"
git push origin main
```

The build workflow automatically triggers. Check GitHub Actions tab for progress.

### 4. Verify CI Pipeline

1. Go to GitHub → Actions
2. Watch "Build" workflow complete
3. Check ghcr.io for new container image:
   ```bash
   gh api user/packages/container/my-service/versions
   ```

## Running Load Tests

### Local Environment (with Grafana)

```bash
# Start local dev environment
make dev-up

# Verify k6 operator is running
kubectl get pods -n k6-operator-system

# Run smoke test
kubectl apply -f deploy/k6/testruns/smoke-test.yaml

# Watch test progress
kubectl logs -f -l app=k6

# View results in Grafana
open http://localhost:3000/d/k6-load-testing
```

### Dev/Staging Environment (external Grafana)

```bash
# Trigger load test via GitHub Actions
gh workflow run load-test.yaml \
  -f test-type=load \
  -f environment=staging

# Or apply directly with kubectl
kubectl apply -f deploy/k6/testruns/load-test.yaml

# Check test status
kubectl get testrun -w
```

## Workflow Reference

### Build Workflow

**Triggers**: Push to `main`, tag `v*`

**What it does**:
1. Runs `cargo fmt` and `cargo clippy`
2. Runs `cargo test`
3. Builds Docker image
4. Pushes to ghcr.io with tags: `sha-<short>`, `v<version>`, `latest`

**Outputs**: `image-tag`, `image-digest`

### Test Workflow

**Triggers**: Pull requests to `main`

**What it does**:
1. Checks code formatting
2. Runs Clippy lints
3. Runs all unit tests
4. Reports results as PR check

### Deploy Workflow

**Triggers**: Called by build workflow, manual dispatch

**What it does**:
1. Checks out `main` branch
2. Updates image tag in `deploy/overlays/<env>/kustomization.yaml`
3. Commits and pushes changes
4. FluxCD detects changes and deploys

### Load Test Workflow

**Triggers**: Manual dispatch, schedule (optional)

**What it does**:
1. Connects to Kubernetes cluster
2. Creates k6 test script ConfigMap
3. Applies TestRun resource
4. Waits for completion
5. Reports results

## k6 Test Types

| Type | Duration | VUs | Purpose |
|------|----------|-----|---------|
| Smoke | 1 minute | 1 | Quick validation |
| Load | 9 minutes | 50 | Sustained traffic |
| Stress | 15 minutes | 100+ | Breaking point |
| Soak | 1+ hours | 50 | Endurance |

## Environment Configuration

### Local Overlay

```yaml
# deploy/overlays/local/kustomization.yaml
resources:
  - ../../base
  - grafana/           # Grafana deployed for local visualization
# k6 operator deployed separately via deploy/k6/base/
```

### Test Overlay

```yaml
# deploy/overlays/test/kustomization.yaml
resources:
  - ../../base
  - grafana/           # Grafana deployed for test environment
# k6 operator deployed separately via deploy/k6/base/
```

### Dev/Prod Overlay

```yaml
# deploy/overlays/dev/kustomization.yaml
resources:
  - ../../base
# Note: No Grafana - uses global/shared instance
# k6 operator deployed separately via deploy/k6/base/
```

## Customizing k6 Tests

### Adding New Test Scenarios

1. Create script in `deploy/k6/tests/`:
   ```javascript
   // my-test.js
   export const options = {
     scenarios: { /* ... */ },
     thresholds: { /* ... */ },
   };
   export default function() { /* ... */ }
   ```

2. Create TestRun manifest in `deploy/k6/testruns/`:
   ```yaml
   apiVersion: k6.io/v1alpha1
   kind: TestRun
   metadata:
     name: my-test
   spec:
     script:
       configMap:
         name: k6-scripts
         file: my-test.js
   ```

3. Apply:
   ```bash
   kubectl apply -f deploy/k6/testruns/my-test.yaml
   ```

### Modifying Thresholds

Edit `deploy/k6/tests/api-load.js`:

```javascript
export const options = {
  thresholds: {
    http_req_duration: ['p(95)<300'],  // Stricter latency
    http_req_failed: ['rate<0.005'],   // Stricter error rate
  },
};
```

## Viewing Results

### Grafana Dashboard

Access Grafana at:
- **Local**: http://localhost:3000
- **Test**: https://grafana.test.example.com
- **Dev/Prod**: https://grafana.example.com (global instance)

Dashboard: **k6 Load Testing**

Key panels:
- Virtual Users over time
- HTTP Request Rate
- HTTP Request Duration (p50, p95, p99)
- Error Rate
- Checks Pass Rate

### CLI Results

```bash
# Get test logs
kubectl logs -l app=k6 --tail=100

# Get test status
kubectl get testrun <name> -o yaml

# Describe test (see events)
kubectl describe testrun <name>
```

## Troubleshooting

### Build Fails

```bash
# Check workflow logs
gh run view --log

# Common issues:
# - Cargo.lock not committed
# - Missing dependencies
# - Clippy warnings treated as errors
```

### k6 Test Fails

```bash
# Check operator logs
kubectl logs -n k6-operator-system -l app.kubernetes.io/name=k6-operator

# Check test pod logs
kubectl logs -l app=k6

# Common issues:
# - Target URL not reachable
# - Prometheus endpoint incorrect
# - Resource limits too low
```

### FluxCD Not Deploying

```bash
# Check Flux status
flux get all

# Force reconciliation
flux reconcile kustomization flux-system

# Check GitRepository sync
flux get sources git
```

## Next Steps

1. **Customize workflows** for your CI/CD requirements
2. **Add k6 tests** for your specific API endpoints
3. **Configure alerts** in Grafana for performance regressions
4. **Set up schedules** for regular load testing
5. **Integrate with PR checks** to prevent performance regressions
