# Research: CI/CD Workflows and k6 Load Testing

**Feature**: 009-ci-workflows-k6  
**Date**: 2026-02-01

## Executive Summary

This research covers three key areas: k6 operator deployment in Kubernetes, Grafana dashboard patterns for k6 metrics, and GitHub Actions GitOps workflows with FluxCD. All technologies are mature and well-documented with production-ready patterns.

---

## 1. k6 Operator (grafana/k6-operator)

### Decision: Use k6 Operator with FluxCD HelmRelease

**Rationale**: The k6 operator provides native Kubernetes integration via TestRun CRDs, enabling declarative load test execution. FluxCD HelmRelease ensures consistent operator deployment across environments.

**Alternatives Considered**:
- Direct k6 CLI in Jobs: Rejected - no parallelism, harder to manage
- k6 Cloud: Rejected - requires external account, not self-hosted

### Deployment Pattern

```yaml
# FluxCD HelmRelease for k6-operator
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: k6-operator
  namespace: k6-operator-system
spec:
  interval: 1h
  chart:
    spec:
      chart: k6-operator
      version: "3.x"
      sourceRef:
        kind: HelmRepository
        name: grafana
        namespace: flux-system
  install:
    createNamespace: true
```

### TestRun CRD Structure

```yaml
apiVersion: k6.io/v1alpha1
kind: TestRun
metadata:
  name: api-load-test
spec:
  parallelism: 4
  script:
    configMap:
      name: k6-test-script
      file: test.js
  arguments: --out experimental-prometheus-rw
  runner:
    image: grafana/k6:latest
    env:
      - name: K6_PROMETHEUS_RW_SERVER_URL
        value: "http://prometheus-server:9090/api/v1/write"
      - name: K6_PROMETHEUS_RW_TREND_STATS
        value: "p(50),p(90),p(95),p(99),min,max,avg"
```

### k6 Script Best Practices

```javascript
import http from 'k6/http';
import { check, group, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const errorRate = new Rate('errors');

export const options = {
  scenarios: {
    smoke: {
      executor: 'constant-vus',
      vus: 1,
      duration: '1m',
      tags: { test_type: 'smoke' },
    },
    load: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: 50 },
        { duration: '5m', target: 50 },
        { duration: '2m', target: 0 },
      ],
      startTime: '1m',
      tags: { test_type: 'load' },
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<500', 'p(99)<1000'],
    http_req_failed: ['rate<0.01'],
    errors: ['rate<0.01'],
  },
};

export default function() {
  group('Health Check', () => {
    const res = http.get(`${__ENV.BASE_URL}/health/live`);
    check(res, { 'status is 200': (r) => r.status === 200 });
    errorRate.add(res.status !== 200);
  });
  sleep(1);
}
```

---

## 2. Grafana Dashboards for k6 Metrics

### Decision: Use Official k6 Prometheus Dashboard with Customizations

**Rationale**: Official dashboard (ID: 19665) provides comprehensive coverage of k6 metrics. Customizations add application-specific panels.

**Alternatives Considered**:
- k6 Cloud dashboards: Rejected - requires k6 Cloud subscription
- Custom dashboards from scratch: Rejected - unnecessary effort when official exists

### Key k6 Prometheus Metrics

| Metric | Prometheus Name | Description |
|--------|-----------------|-------------|
| HTTP Requests | `k6_http_reqs_total` | Total request count |
| Request Duration | `k6_http_req_duration_*` | Latency percentiles |
| Failed Requests | `k6_http_req_failed_rate` | Error rate |
| Virtual Users | `k6_vus` | Active VU count |
| Iterations | `k6_iterations_total` | Completed iterations |
| Data Transfer | `k6_data_received_total`, `k6_data_sent_total` | Bytes transferred |

### Dashboard Panel Organization

1. **Row 1: Overview** - VUs + RPS + Latency combined timeseries
2. **Row 2: Key Stats** - Total requests, failures, peak RPS, p95 latency
3. **Row 3: HTTP Details** - Latency breakdown (blocked, tls, waiting, etc.)
4. **Row 4: URL Breakdown** - Per-endpoint performance table
5. **Row 5: Checks** - Check pass/fail rates

### Kubernetes Dashboard Provisioning

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-provider
  labels:
    grafana_dashboard_provider: "1"
data:
  dashboards.yaml: |
    apiVersion: 1
    providers:
      - name: 'k6-dashboards'
        orgId: 1
        folder: 'k6 Load Testing'
        type: file
        options:
          path: /var/lib/grafana/dashboards/k6
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-k6
  labels:
    grafana_dashboard: "1"
data:
  k6-prometheus.json: |
    { "dashboard JSON content here" }
```

---

## 3. GitHub Actions GitOps with FluxCD

### Decision: Push-Based Image Updates with FluxCD Reconciliation

**Rationale**: Workflows update Kustomize manifests with new image tags; FluxCD polls Git and reconciles. This pattern:
- Keeps CI/CD simple (no cluster access needed)
- Maintains GitOps principles (Git as source of truth)
- Leverages existing FluxCD infrastructure

**Alternatives Considered**:
- Webhook receivers: More complex, requires ingress exposure
- Direct kubectl apply: Violates GitOps principles
- Flux Image Automation: Requires additional CRDs, less control over timing

### Workflow Pattern: Build → Update Manifests → Flux Reconciles

```yaml
name: CI/CD Pipeline
on:
  push:
    branches: [main]
    tags: ['v*']

permissions:
  contents: write
  packages: write

jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      image-tag: ${{ steps.meta.outputs.version }}
      digest: ${{ steps.build.outputs.digest }}
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Docker meta
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/${{ github.repository }}
          tags: |
            type=sha,prefix=sha-,format=short
            type=semver,pattern={{version}}
      - name: Build and push
        id: build
        uses: docker/build-push-action@v6
        with:
          push: true
          tags: ${{ steps.meta.outputs.tags }}

  update-manifests:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Update image in Kustomization
        run: |
          cd deploy/overlays/dev
          kustomize edit set image \
            app=ghcr.io/${{ github.repository }}@${{ needs.build.outputs.digest }}
      - name: Commit and push
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add .
          git diff --staged --quiet || git commit -m "Deploy: ${{ needs.build.outputs.image-tag }}"
          git push
```

### Multi-Environment Strategy

| Environment | Trigger | Approval |
|-------------|---------|----------|
| Dev | Push to main | Automatic |
| Staging | Push to main | Automatic |
| Prod | Git tag v* | PR required |

### Security Best Practices

1. **Minimal Permissions**: `contents: write`, `packages: write` only
2. **GITHUB_TOKEN**: Native token for ghcr.io, no external secrets
3. **Environment Protection**: Use GitHub Environments for prod approvals
4. **Immutable Tags**: SHA-based tags, never `latest`
5. **No Cluster Access**: CI only touches Git, Flux handles deployment

---

## 4. Integration Architecture

```
┌─────────────────┐      ┌─────────────────┐      ┌─────────────────┐
│  GitHub Actions │      │     Git Repo    │      │   Kubernetes    │
│                 │      │                 │      │                 │
│  1. Build image │──────│  2. Push image  │      │                 │
│     & push to   │      │     tag update  │      │                 │
│     ghcr.io     │      │     to deploy/  │      │                 │
│                 │      │                 │      │                 │
└─────────────────┘      └────────┬────────┘      │                 │
                                  │               │                 │
                                  │ 3. FluxCD     │  4. Reconcile   │
                                  │    polls Git  │     manifests   │
                                  │               │                 │
                                  └───────────────►  5. Deploy app  │
                                                  │                 │
                                                  │  6. k6 operator │
                                                  │     runs tests  │
                                                  │                 │
                                                  │  7. Prometheus  │
                                                  │     scrapes k6  │
                                                  │                 │
                                                  │  8. Grafana     │
                                                  │     displays    │
                                                  └─────────────────┘
```

---

## 5. Environment-Specific Configuration

### Local/Test Overlays (WITH Grafana)

```yaml
# deploy/overlays/local/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
  - grafana/
  - k6-operator/
```

### Dev/Prod Overlays (WITHOUT Grafana)

```yaml
# deploy/overlays/dev/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
  - k6-operator/
# Note: No grafana/ - uses global Grafana instance
# k6 configured to send metrics to external Prometheus
```

### k6 External Metrics Configuration (Dev/Prod)

```yaml
# deploy/overlays/dev/k6-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: k6-config
data:
  K6_PROMETHEUS_RW_SERVER_URL: "http://global-prometheus.monitoring.svc:9090/api/v1/write"
```

---

## Summary

| Component | Decision | Key Configuration |
|-----------|----------|-------------------|
| k6 Operator | FluxCD HelmRelease | TestRun CRD with Prometheus remote write |
| Grafana Dashboard | Official k6 dashboard (19665) | ConfigMap provisioning |
| CI/CD | GitHub Actions + GitOps | Push manifest updates, Flux reconciles |
| Container Registry | ghcr.io | GITHUB_TOKEN authentication |
| Metrics Backend | Prometheus | Remote write from k6 |
| Grafana Deployment | Local/Test only | Excluded from dev/prod overlays |
