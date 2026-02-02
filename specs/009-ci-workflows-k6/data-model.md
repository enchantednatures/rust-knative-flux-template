# Data Model: CI/CD Workflows and k6 Load Testing

**Feature**: 009-ci-workflows-k6  
**Date**: 2026-02-01

## Overview

This feature involves configuration files and Kubernetes resources rather than traditional database entities. The "data model" describes the structure of workflows, test scenarios, and dashboard configurations.

---

## 1. GitHub Actions Workflow

### Entity: Workflow Definition

A GitHub Actions workflow YAML file defining CI/CD automation.

| Field | Type | Description | Validation |
|-------|------|-------------|------------|
| `name` | string | Workflow display name | Required, max 100 chars |
| `on` | object | Trigger events | Required, valid GitHub events |
| `permissions` | object | Token permissions | Required, principle of least privilege |
| `env` | object | Environment variables | Optional |
| `jobs` | object | Job definitions | Required, at least one job |

### Job Structure

| Field | Type | Description |
|-------|------|-------------|
| `runs-on` | string | Runner type | 
| `needs` | array | Job dependencies |
| `if` | string | Conditional execution |
| `outputs` | object | Output values for downstream jobs |
| `steps` | array | Ordered list of actions |

### State Transitions

```
[Triggered] → [Queued] → [In Progress] → [Completed/Failed/Cancelled]
```

---

## 2. k6 TestRun (Kubernetes CRD)

### Entity: TestRun

A Kubernetes custom resource defining a k6 load test execution.

| Field | Type | Description | Validation |
|-------|------|-------------|------------|
| `apiVersion` | string | `k6.io/v1alpha1` | Fixed value |
| `kind` | string | `TestRun` | Fixed value |
| `metadata.name` | string | Test run identifier | Required, DNS-compatible |
| `metadata.namespace` | string | Kubernetes namespace | Required |
| `spec.parallelism` | integer | Runner pod count | 1-100, default 1 |
| `spec.script` | object | Script source reference | Required |
| `spec.arguments` | string | k6 CLI arguments | Optional |
| `spec.runner` | object | Runner pod configuration | Optional |

### Script Source (ConfigMap)

| Field | Type | Description |
|-------|------|-------------|
| `configMap.name` | string | ConfigMap name containing script |
| `configMap.file` | string | File key within ConfigMap |

### Runner Configuration

| Field | Type | Description |
|-------|------|-------------|
| `image` | string | k6 container image |
| `env` | array | Environment variables |
| `resources` | object | CPU/memory requests/limits |

### State Transitions

```
[Created] → [Initializing] → [Started] → [Running] → [Finished/Failed/Error]
```

---

## 3. k6 Test Script

### Entity: Load Test Scenario

A JavaScript file defining virtual user behavior and performance thresholds.

| Field | Type | Description | Validation |
|-------|------|-------------|------------|
| `options.scenarios` | object | Test scenario definitions | At least one scenario |
| `options.thresholds` | object | Pass/fail criteria | Metric-based thresholds |
| `options.tags` | object | Labels for filtering | Key-value pairs |
| `setup()` | function | One-time initialization | Optional |
| `default()` | function | VU iteration logic | Required |
| `teardown()` | function | Cleanup logic | Optional |

### Scenario Types

| Type | Description | Use Case |
|------|-------------|----------|
| `constant-vus` | Fixed VU count | Smoke tests |
| `ramping-vus` | VU count changes over time | Load tests |
| `constant-arrival-rate` | Fixed request rate | Stress tests |
| `ramping-arrival-rate` | Request rate changes | Spike tests |

### Threshold Examples

| Metric | Threshold | Description |
|--------|-----------|-------------|
| `http_req_duration` | `p(95)<500` | 95th percentile under 500ms |
| `http_req_failed` | `rate<0.01` | Error rate under 1% |
| `checks` | `rate>0.99` | Check pass rate over 99% |

---

## 4. Grafana Dashboard

### Entity: Dashboard Definition

A JSON file defining Grafana panels and queries.

| Field | Type | Description |
|-------|------|-------------|
| `uid` | string | Unique dashboard identifier |
| `title` | string | Dashboard title |
| `tags` | array | Dashboard tags for filtering |
| `templating.list` | array | Variable definitions |
| `panels` | array | Panel configurations |
| `refresh` | string | Auto-refresh interval |

### Panel Types

| Type | Use Case |
|------|----------|
| `timeseries` | Metrics over time (latency, RPS) |
| `stat` | Single value (total requests, error rate) |
| `table` | Tabular data (per-endpoint breakdown) |
| `gauge` | Current value with thresholds |

### Template Variables

| Variable | Query | Purpose |
|----------|-------|---------|
| `DS_PROMETHEUS` | Datasource selector | Multi-datasource support |
| `testid` | `label_values(testid)` | Filter by test run |
| `scenario` | `label_values(scenario)` | Filter by scenario |

---

## 5. Kustomize Overlay

### Entity: Environment Overlay

A Kustomize configuration for environment-specific deployments.

| Field | Type | Description |
|-------|------|-------------|
| `apiVersion` | string | `kustomize.config.k8s.io/v1beta1` |
| `kind` | string | `Kustomization` |
| `namespace` | string | Target namespace |
| `resources` | array | Resources to include |
| `patches` | array | Strategic merge patches |
| `images` | array | Image tag overrides |

### Overlay Hierarchy

```
deploy/
├── base/                 # Common resources
│   ├── kustomization.yaml
│   └── knative-service.yaml
├── overlays/
│   ├── local/           # + Grafana, + k6
│   │   ├── kustomization.yaml
│   │   └── grafana/
│   ├── test/            # + Grafana, + k6
│   │   ├── kustomization.yaml
│   │   └── grafana/
│   ├── dev/             # No Grafana
│   │   └── kustomization.yaml
│   └── prod/            # No Grafana
│       └── kustomization.yaml
```

---

## 6. Prometheus Metrics (k6 Output)

### Metrics Exported by k6

| Metric Name | Type | Labels |
|-------------|------|--------|
| `k6_http_reqs_total` | counter | `method`, `url`, `status`, `expected_response` |
| `k6_http_req_duration_seconds` | histogram | `method`, `url` |
| `k6_http_req_failed_total` | counter | `method`, `url` |
| `k6_vus` | gauge | `testid` |
| `k6_vus_max` | gauge | `testid` |
| `k6_iterations_total` | counter | `testid`, `scenario` |
| `k6_data_received_total` | counter | `testid` |
| `k6_data_sent_total` | counter | `testid` |
| `k6_checks_total` | counter | `check`, `testid` |

### Trend Metric Suffixes

When `K6_PROMETHEUS_RW_TREND_STATS=p(50),p(90),p(95),p(99),min,max,avg`:

| Suffix | Description |
|--------|-------------|
| `_p50` | 50th percentile |
| `_p90` | 90th percentile |
| `_p95` | 95th percentile |
| `_p99` | 99th percentile |
| `_min` | Minimum value |
| `_max` | Maximum value |
| `_avg` | Average value |

---

## Relationships

```
┌─────────────────┐      ┌─────────────────┐
│    Workflow     │      │    TestRun      │
│   (GitHub)      │      │   (K8s CRD)     │
└────────┬────────┘      └────────┬────────┘
         │                        │
         │ triggers               │ references
         ▼                        ▼
┌─────────────────┐      ┌─────────────────┐
│  Container      │      │   Test Script   │
│   Image         │      │  (ConfigMap)    │
└────────┬────────┘      └────────┬────────┘
         │                        │
         │ deployed by            │ executed by
         ▼                        ▼
┌─────────────────┐      ┌─────────────────┐
│   Kustomize     │      │   k6 Runner     │
│    Overlay      │      │    (Pod)        │
└────────┬────────┘      └────────┬────────┘
         │                        │
         │ configures             │ exports to
         ▼                        ▼
┌─────────────────┐      ┌─────────────────┐
│    Grafana      │◄─────│   Prometheus    │
│   Dashboard     │      │    Metrics      │
└─────────────────┘      └─────────────────┘
```
