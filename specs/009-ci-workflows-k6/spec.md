# Feature Specification: CI/CD Workflows and k6 Load Testing

**Feature Branch**: `009-ci-workflows-k6`  
**Created**: 2026-02-01  
**Status**: Draft  
**Input**: User description: "when this template generates a repo, it needs to be prepopulated with the github workflows for building, testing and deploying. we probably also want some k6 load tests that can run too to make sure that the api is well scalable. these k6 tests should run in the kubernetes cluster and have grafana dashboards for them. this should not deploy grafana except in the local and test overlays (dev and prod overlays will have a global grafana)"

## Clarifications

### Session 2026-02-01

- Q: Which container registry should the build workflow push images to? → A: GitHub Container Registry (ghcr.io)
- Q: Which metrics backend should k6 export results to for Grafana visualization? → A: Prometheus (via remote write)
- Q: What deployment trigger strategy should the deploy workflow use? → A: GitOps via FluxCD (workflow updates manifests, Flux reconciles)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Template Repository Generation with CI/CD (Priority: P1)

As a developer using this template to bootstrap a new project, I want the generated repository to include ready-to-use GitHub Actions workflows so that I can immediately start building, testing, and deploying my application without manual CI/CD setup.

**Why this priority**: This is the core value proposition - developers need working CI/CD from day one. Without this, the template provides minimal value for production use.

**Independent Test**: Can be fully tested by generating a new repository from the template and verifying that all workflows exist, are syntactically valid, and can be triggered. Delivers immediate CI/CD capability.

**Acceptance Scenarios**:

1. **Given** a developer creates a new repository from this template, **When** they push code to the main branch, **Then** the build workflow automatically triggers and compiles the Rust application.
2. **Given** a developer opens a pull request, **When** the PR is created or updated, **Then** the test workflow runs all unit and integration tests and reports results.
3. **Given** a successful build on the main branch, **When** deployment is triggered, **Then** the deploy workflow packages and deploys the application to the target environment.
4. **Given** a developer clones the generated repository, **When** they inspect the `.github/workflows` directory, **Then** they find documented, well-structured workflow files for build, test, and deploy.

---

### User Story 2 - Load Testing Execution in Kubernetes (Priority: P2)

As a platform engineer, I want to run k6 load tests within the Kubernetes cluster so that I can validate API scalability under realistic conditions and identify performance bottlenecks before production traffic.

**Why this priority**: Load testing is essential for validating scalability claims but depends on having a deployed application first (P1). It provides critical performance validation before production.

**Independent Test**: Can be fully tested by deploying the k6 test runner to a Kubernetes cluster, executing a test scenario against the API, and verifying results are captured. Delivers performance validation capability.

**Acceptance Scenarios**:

1. **Given** an API deployed in Kubernetes, **When** I trigger a k6 load test, **Then** the test runs within the cluster and generates performance metrics.
2. **Given** a k6 test execution, **When** the test completes, **Then** results include response times, error rates, and throughput measurements.
3. **Given** the local or test overlay is deployed, **When** I run load tests, **Then** the k6 operator executes tests as Kubernetes jobs within the cluster.
4. **Given** a failed load test (performance below threshold), **When** results are analyzed, **Then** clear indicators show which metrics failed and by how much.

---

### User Story 3 - Load Test Results Visualization (Priority: P3)

As a platform engineer, I want to visualize k6 load test results in Grafana dashboards so that I can analyze performance trends, identify patterns, and share results with stakeholders.

**Why this priority**: Visualization enhances the value of load testing but is not required for basic performance validation. Provides operational insights and reporting capability.

**Independent Test**: Can be fully tested by running a load test, navigating to Grafana, and verifying the dashboard displays real-time and historical k6 metrics. Delivers visual analytics capability.

**Acceptance Scenarios**:

1. **Given** a k6 load test running, **When** I access Grafana in the local/test environment, **Then** I see real-time metrics being displayed on the k6 dashboard.
2. **Given** multiple load test executions, **When** I view the Grafana dashboard, **Then** I can compare historical test runs and identify trends.
3. **Given** the dev or prod overlay is deployed, **When** I need to view k6 metrics, **Then** data is sent to the global Grafana instance (no local Grafana deployed).

---

### User Story 4 - Environment-Specific Grafana Deployment (Priority: P3)

As a platform engineer, I want Grafana deployed only in local and test environments so that development teams have self-contained observability while production uses the centralized global Grafana.

**Why this priority**: Environment-specific configuration is important for operational efficiency but doesn't block core functionality. Ensures proper resource usage across environments.

**Independent Test**: Can be fully tested by deploying each overlay (local, test, dev, prod) and verifying Grafana presence/absence matches the expected configuration. Delivers environment-appropriate observability.

**Acceptance Scenarios**:

1. **Given** the local overlay is deployed, **When** I check deployed resources, **Then** Grafana is running with k6 dashboards pre-configured.
2. **Given** the test overlay is deployed, **When** I check deployed resources, **Then** Grafana is running with k6 dashboards pre-configured.
3. **Given** the dev overlay is deployed, **When** I check deployed resources, **Then** Grafana is NOT deployed (uses global Grafana).
4. **Given** the prod overlay is deployed, **When** I check deployed resources, **Then** Grafana is NOT deployed (uses global Grafana).

---

### Edge Cases

- What happens when a workflow job fails mid-execution? The workflow should report clear failure status and logs for debugging.
- How does the system handle k6 tests when the target API is unavailable? Tests should fail gracefully with clear error messages indicating connection failures.
- What happens if Grafana is accidentally deployed to dev/prod? Kustomize overlays should explicitly exclude Grafana components to prevent accidental deployment.
- How are workflow secrets managed for different deployment targets? Secrets should be referenced via GitHub Secrets, not hardcoded.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Template MUST include a GitHub Actions workflow for building the Rust application with release and debug profiles
- **FR-002**: Template MUST include a GitHub Actions workflow for running unit tests and integration tests
- **FR-003**: Template MUST include a GitHub Actions workflow for deploying the application to Kubernetes environments
- **FR-004**: Build workflow MUST produce container images and push to GitHub Container Registry (ghcr.io) using native GITHUB_TOKEN authentication
- **FR-005**: Test workflow MUST run on pull requests and report test results as PR checks
- **FR-006**: Deploy workflow MUST follow GitOps pattern: workflow updates Kustomize manifests with new image tags, FluxCD reconciles to target environments
- **FR-007**: Template MUST include k6 load test scripts for common API endpoints (health checks, primary endpoints)
- **FR-008**: k6 tests MUST be executable as Kubernetes jobs using the k6 operator or equivalent
- **FR-009**: k6 test results MUST be exported to Prometheus via remote write, consistent with existing observability stack
- **FR-010**: Template MUST include Grafana dashboard definitions for visualizing k6 metrics
- **FR-011**: Local overlay MUST deploy Grafana with pre-configured k6 dashboards
- **FR-012**: Test overlay MUST deploy Grafana with pre-configured k6 dashboards
- **FR-013**: Dev overlay MUST NOT deploy Grafana (assumes global Grafana exists)
- **FR-014**: Prod overlay MUST NOT deploy Grafana (assumes global Grafana exists)
- **FR-015**: k6 configuration in dev/prod overlays MUST output metrics to external Grafana endpoint
- **FR-016**: Workflows MUST use GitHub Secrets for sensitive configuration (registry credentials, deployment keys)

### Non-Functional Requirements *(mandatory per constitution)*

- **NFR-001**: All public async functions MUST use `#[instrument]` macro for tracing
- **NFR-002**: All errors MUST be logged with context before returning via `tracing::error!`
- **NFR-003**: All endpoints MUST emit Prometheus-compatible metrics
- **NFR-004**: System MUST propagate B3 headers for distributed tracing
- **NFR-005**: Configuration MUST support environment variable overrides with `APP__` prefix
- **NFR-006**: Error handling MUST use `thiserror` with `IntoResponse` implementation
- **NFR-007**: Cold startup time SHOULD be <2 seconds per Knative constraints
- **NFR-008**: Workflows SHOULD complete build jobs within 10 minutes for typical changes
- **NFR-009**: k6 tests SHOULD support configurable virtual user counts and duration
- **NFR-010**: Grafana dashboards SHOULD load within 5 seconds with up to 1 hour of test data

### Key Entities

- **Workflow**: A GitHub Actions workflow definition specifying triggers, jobs, and steps for CI/CD automation
- **Load Test Scenario**: A k6 script defining virtual user behavior, request patterns, and performance thresholds
- **Test Result**: Performance metrics from a k6 execution including response times, error rates, throughput, and pass/fail status
- **Dashboard**: A Grafana dashboard configuration displaying k6 metrics with panels for latency, throughput, errors, and trends
- **Overlay**: A Kustomize overlay that patches base configurations for environment-specific deployments (local, test, dev, prod)

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Developers can generate a new repository and have a working CI pipeline within 5 minutes of first push
- **SC-002**: All three core workflows (build, test, deploy) pass validation when generated repository is created
- **SC-003**: k6 load tests can simulate at least 100 concurrent users against the API
- **SC-004**: Load test execution completes within 15 minutes for standard test scenarios
- **SC-005**: Grafana dashboards display k6 metrics within 30 seconds of test execution start
- **SC-006**: Zero manual configuration required to run k6 tests in local/test environments
- **SC-007**: Environment overlays correctly include/exclude Grafana based on target environment (100% accuracy)
- **SC-008**: Template documentation enables a new user to understand and customize workflows within 30 minutes

## Assumptions

- GitHub Actions is the CI/CD platform (industry standard for GitHub-hosted projects)
- k6 operator is available for running k6 tests in Kubernetes (standard approach for k6 + K8s)
- Grafana datasource for k6 metrics uses Prometheus, aligning with the existing Kubernetes observability stack
- Container images are published to GitHub Container Registry (ghcr.io) co-located with source code
- Global Grafana in dev/prod environments is pre-configured to accept metrics from external sources
- Kustomize is used for environment-specific configuration (already established in project structure)
