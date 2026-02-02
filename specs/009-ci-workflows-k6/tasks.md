# Implementation Tasks: CI/CD Workflows and k6 Load Testing

**Feature Branch**: `009-ci-workflows-k6`  
**Generated**: 2026-02-01  
**Plan**: [plan.md](./plan.md) | **Spec**: [spec.md](./spec.md)

## Overview

| Metric | Count |
|--------|-------|
| Total Tasks | 24 |
| Phase 1 (Setup) | 2 |
| Phase 2 (Foundational) | 4 |
| Phase 3 - US1 (P1 MVP) | 6 |
| Phase 4 - US2 (P2) | 5 |
| Phase 5 - US3 (P3) | 3 |
| Phase 6 - US4 (P3) | 3 |
| Phase 7 (Polish) | 1 |

**MVP Scope**: Phases 1-3 (12 tasks) - Core CI/CD workflows for immediate developer value  
**Parallel Opportunities**: T003-T004, T005-T006, T007-T009, T011-T013, T016-T018, T019-T021

---

## Phase 1: Setup (Prerequisites)

- [x] **T001** [P] [SETUP] Create `.github/workflows/` directory structure
  - Path: `.github/workflows/`
  - Acceptance: Directory exists, ready for workflow files

- [x] **T002** [P] [SETUP] Create `deploy/k6/` directory structure
  - Path: `deploy/k6/base/`, `deploy/k6/tests/`, `deploy/k6/dashboards/`, `deploy/k6/testruns/`
  - Acceptance: All k6-related directories exist

---

## Phase 2: Foundational (Infrastructure Base)

- [x] **T003** [F] [US2] Create k6 operator base Kustomization
  - Path: `deploy/k6/base/kustomization.yaml`
  - Acceptance: References k6-operator namespace and resources
  - Contract: Follow existing `deploy/base/kustomization.yaml.liquid` patterns

- [x] **T004** [F] [US2] Create k6 operator deployment manifest
  - Path: `deploy/k6/base/k6-operator.yaml`
  - Acceptance: Deploys k6-operator from grafana/k6-operator Helm chart or manifests
  - Ref: https://github.com/grafana/k6-operator

- [x] **T005** [F] [US4] Create local overlay base structure
  - Path: `deploy/overlays/local/kustomization.yaml`
  - Acceptance: Extends base, includes observability resources
  - Pattern: Follow existing `deploy/overlays/dev/kustomization.yaml` structure

- [x] **T006** [F] [US4] Create test overlay base structure
  - Path: `deploy/overlays/test/kustomization.yaml`
  - Acceptance: Extends base, includes observability resources
  - Pattern: Follow existing `deploy/overlays/staging/kustomization.yaml` structure

---

## Phase 3: US1 - CI/CD Workflows (P1 - MVP)

> **User Story 1**: As a developer using this template, I want ready-to-use GitHub Actions workflows so I can immediately start building, testing, and deploying.

- [x] **T007** [US1] Create build workflow template
  - Path: `.github/workflows/build.yaml.liquid`
  - Contract: `contracts/workflow-contract.yaml` (Build section)
  - Requirements: FR-001, FR-004
  - Acceptance:
    - Triggers on push to main and tags v*
    - Builds container image with Docker Buildx
    - Pushes to ghcr.io using GITHUB_TOKEN
    - Outputs image-tag and image-digest
    - Uses layer caching (target: <10 min build)

- [x] **T008** [US1] Create test workflow template
  - Path: `.github/workflows/test.yaml.liquid`
  - Contract: `contracts/workflow-contract.yaml` (Test section)
  - Requirements: FR-002, FR-005
  - Acceptance:
    - Triggers on PR and push to main
    - Runs `cargo fmt --check` and `cargo clippy`
    - Runs `cargo test --all-features`
    - Spins up service containers (redis) for integration tests
    - Reports results as PR checks

- [x] **T009** [US1] Create deploy workflow template
  - Path: `.github/workflows/deploy.yaml.liquid`
  - Contract: `contracts/workflow-contract.yaml` (Deploy section)
  - Requirements: FR-003, FR-006, FR-016
  - Acceptance:
    - Triggered by workflow_call (from build) and workflow_dispatch
    - Updates Kustomize overlay with new image digest
    - Commits manifest changes to trigger FluxCD reconciliation
    - Supports dev, staging, prod environments
    - Uses GitHub Secrets for credentials

- [x] **T010** [US1] Create load-test workflow template
  - Path: `.github/workflows/load-test.yaml.liquid`
  - Contract: `contracts/workflow-contract.yaml` (Load Test section)
  - Requirements: FR-008
  - Acceptance:
    - Triggered by workflow_dispatch
    - Supports smoke, load, stress test types
    - Creates k6-scripts ConfigMap from test files
    - Applies TestRun CRD and waits for completion
    - Outputs test results from k6 pod logs

- [x] **T011** [US1] Update build workflow to call deploy
  - Path: `.github/workflows/build.yaml.liquid`
  - Dependency: T007, T009
  - Acceptance:
    - Adds job that calls deploy workflow after successful build
    - Passes image-tag and image-digest as inputs
    - Conditional on main branch (not tags)

- [x] **T012** [US1] Add workflow documentation comments
  - Path: `.github/workflows/*.yaml.liquid`
  - Dependency: T007, T008, T009, T010
  - Requirements: SC-008
  - Acceptance:
    - Each workflow has header comments explaining purpose
    - Liquid template variables are documented
    - Customization points are highlighted

---

## Phase 4: US2 - k6 Load Testing (P2)

> **User Story 2**: As a platform engineer, I want to run k6 load tests within Kubernetes to validate API scalability.

- [x] **T013** [US2] Create health-check k6 test script
  - Path: `deploy/k6/tests/health-check.js`
  - Contract: `contracts/k6-script-template.js`
  - Requirements: FR-007
  - Acceptance:
    - Tests `/health/live` and `/health/ready` endpoints
    - Defines thresholds: p95 < 200ms, error rate < 1%
    - Uses constant-vus scenario (smoke test)
    - Configurable via environment variables (K6_TARGET_URL)

- [x] **T014** [US2] Create API load test script
  - Path: `deploy/k6/tests/api-load.js`
  - Contract: `contracts/k6-script-template.js`
  - Requirements: FR-007, SC-003
  - Acceptance:
    - Tests primary API endpoints
    - Defines ramping-vus scenario: 0->50->100->50->0 VUs
    - Thresholds: p95 < 500ms, p99 < 1000ms, error rate < 1%
    - Supports 100+ concurrent VUs (SC-003)
    - Duration configurable (default: 5 minutes)

- [x] **T015** [US2] Create smoke TestRun CRD manifest
  - Path: `deploy/k6/testruns/smoke-test.yaml`
  - Contract: `contracts/testrun-crd.yaml`
  - Requirements: FR-008, FR-009
  - Acceptance:
    - References health-check.js script via ConfigMap
    - Configures Prometheus remote write output
    - Sets parallelism: 1
    - Includes resource limits

- [x] **T016** [US2] Create load TestRun CRD manifest
  - Path: `deploy/k6/testruns/load-test.yaml`
  - Contract: `contracts/testrun-crd.yaml`
  - Requirements: FR-008, FR-009, SC-004
  - Acceptance:
    - References api-load.js script via ConfigMap
    - Configures Prometheus remote write output
    - Sets parallelism: 2-4 for distributed load
    - Completes within 15 minutes (SC-004)

- [x] **T017** [US2] Create stress TestRun CRD manifest
  - Path: `deploy/k6/testruns/stress-test.yaml`
  - Contract: `contracts/testrun-crd.yaml`
  - Requirements: FR-008, FR-009
  - Acceptance:
    - References api-load.js with aggressive thresholds
    - Uses constant-arrival-rate scenario
    - Higher parallelism for stress testing
    - Configurable target RPS

---

## Phase 5: US3 - Grafana Dashboards (P3)

> **User Story 3**: As a platform engineer, I want to visualize k6 results in Grafana for performance analysis.

- [x] **T018** [US3] Create k6 Grafana dashboard definition
  - Path: `deploy/k6/dashboards/k6-dashboard.json`
  - Contract: `contracts/grafana-dashboard-schema.json`
  - Requirements: FR-010, SC-005, NFR-010
  - Acceptance:
    - Panels: VUs, request rate, latency percentiles, error rate, checks
    - Template variables: testid, scenario, DS_PROMETHEUS
    - Auto-refresh: 5s during tests
    - Loads within 5 seconds (SC-005)
    - Uses existing Prometheus datasource

- [x] **T019** [US3] Create Grafana deployment for local overlay
  - Path: `deploy/overlays/local/grafana/`
  - Requirements: FR-011
  - Acceptance:
    - Grafana deployment manifest
    - Service exposing port 3000
    - ConfigMap with datasource (Prometheus) provisioning
    - ConfigMap with k6-dashboard.json provisioning
    - PersistentVolumeClaim for dashboard storage (optional)

- [x] **T020** [US3] Create Grafana deployment for test overlay
  - Path: `deploy/overlays/test/grafana/`
  - Requirements: FR-012
  - Acceptance:
    - Same structure as local overlay
    - May reference shared base via Kustomize

---

## Phase 6: US4 - Environment Overlays (P3)

> **User Story 4**: As a platform engineer, I want Grafana only in local/test environments.

- [x] **T021** [US4] Update local overlay to include Grafana
  - Path: `deploy/overlays/local/kustomization.yaml`
  - Dependency: T005, T019
  - Requirements: FR-011, SC-007
  - Acceptance:
    - Resources include `grafana/` directory
    - Includes k6 operator base
    - Prometheus configured for local development

- [x] **T022** [US4] Update test overlay to include Grafana
  - Path: `deploy/overlays/test/kustomization.yaml`
  - Dependency: T006, T020
  - Requirements: FR-012, SC-007
  - Acceptance:
    - Resources include `grafana/` directory
    - Includes k6 operator base
    - Prometheus endpoint configured for test environment

- [x] **T023** [US4] Verify dev/prod overlays exclude Grafana
  - Path: `deploy/overlays/dev/kustomization.yaml`, `deploy/overlays/prod/kustomization.yaml`
  - Requirements: FR-013, FR-014, FR-015, SC-007
  - Acceptance:
    - No Grafana resources referenced
    - k6 output configured to external Prometheus endpoint
    - Document that global Grafana is assumed
    - Add comment explaining Grafana exclusion

---

## Phase 7: Polish (Documentation & Validation)

- [x] **T024** [P] [ALL] Validate all manifests and update documentation
  - Paths: All created files
  - Requirements: SC-001, SC-002, SC-006, SC-008
  - Acceptance:
    - All YAML files pass `kustomize build` validation
    - All workflow files pass `actionlint` or similar
    - quickstart.md updated with actual file paths
    - AGENTS.md updated if needed
    - README references new workflows

---

## Task Dependencies

```
T001 ─┬─> T007 ─┬─> T011 ──> T012
      │        │
      │        ├─> T008 ──> T012
      │        │
      │        ├─> T009 ──> T011
      │        │
      └─> T010 ────────────> T012

T002 ─┬─> T003 ──> T015 ─┬─> T016
      │                  │
      ├─> T004 ─────────┘└─> T017
      │
      ├─> T013 ──> T015
      │
      └─> T014 ─┬─> T016
                └─> T017

T005 ─┬─> T019 ──> T021
      │
T006 ─┴─> T020 ──> T022

T018 ─┬─> T019
      └─> T020

T021 ─┬
T022 ─┼─> T023 ──> T024
T023 ─┘
```

## Parallel Execution Groups

| Group | Tasks | Description |
|-------|-------|-------------|
| Setup | T001, T002 | Can run in parallel |
| Foundational | T003+T004, T005+T006 | Two parallel pairs |
| Workflows | T007, T008, T009, T010 | All independent |
| k6 Scripts | T013, T014 | Independent |
| TestRuns | T015, T016, T017 | Independent after scripts |
| Grafana | T018, T019, T020 | Dashboard first, then deployments |
| Overlays | T021, T022, T023 | After Grafana deployments |

## User Story Mapping

| User Story | Tasks | Priority |
|------------|-------|----------|
| US1 - CI/CD Workflows | T007, T008, T009, T010, T011, T012 | P1 (MVP) |
| US2 - k6 Load Testing | T003, T004, T013, T014, T015, T016, T017 | P2 |
| US3 - Grafana Dashboards | T018, T019, T020 | P3 |
| US4 - Environment Overlays | T005, T006, T021, T022, T023 | P3 |
| Setup/Polish | T001, T002, T024 | Infrastructure |

## MVP Definition

**MVP (P1)**: Tasks T001, T007, T008, T009, T010, T011, T012

Delivers:
- Working build workflow (ghcr.io push)
- Working test workflow (PR checks)
- Working deploy workflow (GitOps via FluxCD)
- Load test workflow structure (manual trigger)
- Immediate CI/CD value on template generation

**Post-MVP**: k6 infrastructure, Grafana dashboards, environment-specific observability
