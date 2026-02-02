# Implementation Plan: CI/CD Workflows and k6 Load Testing

**Branch**: `009-ci-workflows-k6` | **Date**: 2026-02-01 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/009-ci-workflows-k6/spec.md`

## Summary

This feature adds GitHub Actions workflows for CI/CD automation (build, test, deploy) to the template repository and introduces k6 load testing infrastructure with Grafana dashboards. The workflows use GitHub Container Registry (ghcr.io) for images and follow GitOps patterns via FluxCD. k6 tests run as Kubernetes jobs via the k6 operator, exporting metrics to Prometheus for visualization in Grafana. Grafana is deployed only in local/test overlays; dev/prod rely on external global Grafana.

## Technical Context

**Language/Version**: YAML (GitHub Actions workflows), JavaScript (k6 test scripts), JSON (Grafana dashboards), Rust 1.75+ (existing application)  
**Primary Dependencies**: GitHub Actions, k6 operator (grafana/k6-operator), Prometheus, Grafana, FluxCD, Kustomize  
**Storage**: Prometheus (metrics time-series), GitHub Container Registry (container images)  
**Testing**: Workflow validation via `act` or dry-run, k6 test execution verification  
**Target Platform**: Kubernetes (Knative Serving), GitHub Actions runners  
**Project Type**: Template repository with Kustomize overlays  
**Performance Goals**: CI build <10 minutes, k6 supports 100+ concurrent VUs, Grafana dashboard loads <5 seconds  
**Constraints**: ghcr.io for images, Prometheus for k6 metrics, GitOps via FluxCD for deployments  
**Scale/Scope**: 4 environment overlays (local, test, dev, prod), 3 core workflows (build, test, deploy), 1 k6 test suite

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### Mandatory Checks

- [x] **Observability**: This feature adds observability infrastructure (Prometheus metrics for k6, Grafana dashboards). Existing application code already uses `#[instrument]` macro; this feature extends observability to CI/CD and load testing.
- [x] **Testing**: Workflows include test jobs; k6 provides load/performance testing; workflow validation can be tested via template generation. No new Rust code requiring unit tests.
- [x] **Configuration**: Environment overlays follow existing Kustomize pattern; secrets via GitHub Secrets (not in repository); overlay-specific Grafana configuration.
- [x] **Error Handling**: Workflows report failures via GitHub Actions status; k6 tests have thresholds that fail on errors; Grafana alerts can be configured for metric thresholds.
- [x] **Performance**: Workflows target <10 minutes; k6 tests validate application performance; no impact on application cold start.
- [x] **Knative Constraints**: k6 tests target health endpoints and API; existing `/health/live` and `/health/ready` endpoints tested. No changes to Knative service configuration.

### Complexity Tracking

No constitution violations. This feature adds infrastructure (workflows, k6, Grafana) without modifying existing Rust application code.

## Project Structure

### Documentation (this feature)

```text
specs/009-ci-workflows-k6/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output (k6 test scenarios, dashboard schemas)
└── tasks.md             # Phase 2 output
```

### Source Code (repository root)

```text
.github/
└── workflows/
    ├── ci.yaml.liquid       # Existing - enhanced with deploy job
    ├── build.yaml.liquid    # NEW - dedicated build workflow
    ├── test.yaml.liquid     # NEW - dedicated test workflow  
    └── deploy.yaml.liquid   # NEW - GitOps deployment workflow

deploy/
├── base/
│   └── (existing Kustomize base)
├── overlays/
│   ├── local/               # NEW - local development overlay
│   │   ├── kustomization.yaml
│   │   └── grafana/         # Grafana deployment for local
│   ├── test/                # NEW - test environment overlay
│   │   ├── kustomization.yaml
│   │   └── grafana/         # Grafana deployment for test
│   ├── dev/
│   │   └── kustomization.yaml  # NO Grafana (uses global)
│   ├── staging/
│   │   └── kustomization.yaml  # Existing
│   └── prod/
│       └── kustomization.yaml  # NO Grafana (uses global)
├── dev/
│   └── observability/
│       ├── kustomization.yaml  # Existing - add Grafana
│       ├── grafana/            # NEW - Grafana deployment
│       └── k6/                 # NEW - k6 operator resources
└── k6/                         # NEW - k6 test infrastructure
    ├── base/
    │   ├── kustomization.yaml
    │   └── k6-operator.yaml
    ├── tests/
    │   ├── health-check.js     # k6 script for health endpoints
    │   └── api-load.js         # k6 script for API load testing
    └── dashboards/
        └── k6-dashboard.json   # Grafana dashboard definition

tests/
└── k6/                         # k6 test scripts (symlink or copy)
```

**Structure Decision**: Extends existing Kustomize overlay pattern with new `local` and `test` overlays. k6 infrastructure lives under `deploy/k6/` following existing infrastructure conventions. Grafana added to `deploy/dev/observability/` for local development.

## Post-Design Constitution Re-Check

*Re-evaluated after Phase 1 design completion.*

### Mandatory Checks (Post-Design)

- [x] **Observability**: ✅ VERIFIED
  - k6 exports metrics to Prometheus via remote write
  - Grafana dashboard provides visualization of all k6 metrics
  - Dashboard includes: VUs, request rate, latency percentiles, error rate, checks
  - No changes to existing application tracing/logging

- [x] **Testing**: ✅ VERIFIED
  - Workflows include dedicated test job with `cargo test`
  - k6 provides load/performance testing with thresholds
  - Test contracts defined in `contracts/k6-script-template.js`
  - Smoke, load, stress scenarios documented

- [x] **Configuration**: ✅ VERIFIED
  - Environment overlays follow Kustomize pattern (local, test, dev, prod)
  - Secrets via GitHub Secrets and Kubernetes Secrets (never in repo)
  - k6 Prometheus endpoint configurable per environment
  - Grafana deployed only in local/test overlays

- [x] **Error Handling**: ✅ VERIFIED
  - Workflows report failures via GitHub Actions status checks
  - k6 thresholds define pass/fail criteria
  - TestRun CRD has status conditions for monitoring
  - Dashboard shows error rates and failed checks

- [x] **Performance**: ✅ VERIFIED
  - Build workflow uses Docker layer caching (target: <10 min)
  - k6 supports parallelism for 100+ VUs
  - Grafana dashboard targets <5s load time
  - No impact on application cold start

- [x] **Knative Constraints**: ✅ VERIFIED
  - k6 tests target `/health/live` and `/health/ready` endpoints
  - No modifications to Knative Service configuration
  - Existing port 8080, SIGTERM handling, B3 propagation unchanged

### Complexity Tracking

No constitution violations identified. All mandatory checks pass.

## Phase 1 Artifacts Generated

| Artifact | Path | Status |
|----------|------|--------|
| Research | `research.md` | ✅ Complete |
| Data Model | `data-model.md` | ✅ Complete |
| TestRun CRD Contract | `contracts/testrun-crd.yaml` | ✅ Complete |
| k6 Script Template | `contracts/k6-script-template.js` | ✅ Complete |
| Workflow Contract | `contracts/workflow-contract.yaml` | ✅ Complete |
| Dashboard Schema | `contracts/grafana-dashboard-schema.json` | ✅ Complete |
| Quickstart Guide | `quickstart.md` | ✅ Complete |
| Agent Context | `AGENTS.md` (updated) | ✅ Complete |

## Next Steps

Run `/speckit.tasks` to generate implementation tasks from this plan.
