# Rust Knative Flux Template Constitution

## Core Principles

### I. Observability-First

Every component MUST emit structured telemetry:

- **Tracing**: All public async functions use `#[instrument]` macro from `tracing` to capture
  function entry/exit. Explicit `tracing::` calls reserved for progress logging,
  error context, and business-significant events (not function entry/exit).
- **Logging**: Structured JSON logs with contextual fields via `tracing`. Log errors
  with full context before returning.
- **Metrics**: Prometheus-compatible metrics for all endpoints and operations.
- **Context Propagation**: B3 headers for distributed tracing across all services.

**Rationale**: Serverless environments demand deep observability for debugging
distributed issues. Knative requires B3 propagation for trace continuity. Structured
logs enable automated analysis and alerting.

### II. Test-Driven Development

Tests are NON-NEGOTIABLE and precede implementation:

- **Unit Tests**: All modules have `#[cfg(test)]` sections with test cases for
  business logic.
- **Integration Tests**: Full handler tests in `tests/` directory using
  `axum::TestServer` or equivalent.
- **E2E Tests**: End-to-end workflow verification in Kind cluster for all
  critical paths.
- **Test Execution**: `cargo test --all-features -- --ignored` must pass in CI
  before any PR can merge.

**Rationale**: Template serves as production code. Without tests, generated projects
inherit technical debt. E2E tests ensure Knative integration works end-to-end.

### III. Configuration Hierarchy

Configuration MUST follow three-tier hierarchy (highest to lowest priority):

1. **Environment Variables**: Prefix with `APP__` (e.g., `APP__REDIS__URL`)
2. **Environment-Specific Files**: `config/{environment}.toml` (development.toml,
   production.toml)
3. **Default File**: `config/default.toml`

Environment variables ALWAYS override file-based configuration. Secrets MUST
NEVER be committed to repository; use Kubernetes secrets.

**Rationale**: Enables flexibility across environments without rebuilding.
Environment variables map naturally to Kubernetes ConfigMaps/Secrets. Security:
secrets never in code.

### IV. Error Handling Discipline

All errors handled via `thiserror` for consistent, typed error handling:

- **Custom Error Types**: Use `#[derive(Error, Debug)]` with `#[error]` attributes
  for all domain errors.
- **Propagation**: Use `?` operator throughout; never `.unwrap()` or
  `.expect()` in production code.
- **IntoResponse**: Implement `IntoResponse` trait for `AppError` to convert errors
  to HTTP responses with appropriate status codes.
- **Context**: Log errors with full context before returning via
  `tracing::error!(error = %e, "Operation failed")`.

**Rationale**: Consistent error handling prevents silent failures. Typed errors
enable precise handling at boundaries. Logging context is critical for debugging
serverless ephemeral pods.

### V. Performance & Startup Time

Services MUST optimize for fast cold starts (<2 seconds preferred):

- **Blocking Operations Minimized**: All I/O (network, file, database) MUST use
  async/await with tokio runtime.
- **Connection Pooling**: Reuse connections (Redis, S3, etc.) via `AppState`
  rather than per-request connections.
- **Lazy Initialization**: Defer non-critical work until after readiness probe
  passes.
- **Port 8080**: Knative requires port 8080; hard-code this, never make configurable.

**Rationale**: Knative scale-to-zero makes cold start latency user-visible.
Sub-second startup directly impacts user experience. Connection pooling prevents
exhaustion.

## Knative Constraints

All generated services MUST comply with Knative Serving requirements:

- **Port 8080**: Application MUST listen on port 8080 (hard requirement).
- **Health Endpoints**: Implement `/health/live` (liveness) and `/health/ready`
  (readiness) endpoints. Liveness MUST succeed even if dependencies are down;
  readiness MUST check critical dependencies (Redis, S3).
- **Graceful Shutdown**: Handle SIGTERM signal with 30-second grace period; close
  connections, finish in-flight requests.
- **B3 Propagation**: Accept and propagate B3 headers (trace_id, span_id) via
  opentelemetry-zipkin for distributed tracing.
- **Read-Only Root**: Use non-root user and read-only root filesystem in container.

**Rationale**: Knative enforces these constraints for proper autoscaling and
zero-downtime deployments. Violations cause deployment failures or runtime
instability.

## Development Standards

### Code Organization

- **Modules**: Organize by domain (handlers/, config.rs, state.rs, error.rs,
  observability.rs).
- **One Module Per File**: Use `mod.rs` for public re-exports; keep files focused.
- **lib.rs**: Public API exports only; `main.rs` is application entry point only.

### Import Style

```rust
// Standard library
use std::sync::Arc;
use std::time::Duration;

// External crates (alphabetical)
use axum::{extract::State, Json};
use serde::{Deserialize, Serialize};

// Internal modules (relative or crate-level)
use crate::config::Config;
use crate::error::AppError;
```

### Naming Conventions

- **Types**: `PascalCase` (e.g., `AppState`, `HealthResponse`)
- **Functions**: `snake_case` (e.g., `create_router`, `init_telemetry`)
- **Constants**: `SCREAMING_SNAKE_CASE` (e.g., `MAX_RETRIES`)
- **Lifetimes**: Short, descriptive (e.g., `'a`, `'static`)
- **Generic Types**: Single uppercase letter or descriptive (e.g., `T`, `TState`)

### Documentation

All public functions MUST have doc comments:

```rust
/// Brief one-line description
///
/// Longer description with more context.
///
/// # Arguments
///
/// * `key` - Description of parameter
///
/// # Returns
///
/// Returns `Ok(())` on success, `Err(AppError)` on failure
///
/// # Errors
///
/// Returns error if connection fails or timeout occurs
pub async fn upload_file(key: &str, data: &[u8]) -> Result<(), AppError> {
    // Implementation
}
```

### Commit Messages

Follow Conventional Commits format:
```
<type>(<scope>): <subject>

Types: feat, fix, docs, style, refactor, test, chore
Examples:
  feat(api): add user endpoint
  fix(storage): resolve S3 timeout
  docs(readme): update deployment instructions
```

## Testing Requirements

### Test Categories

1. **Unit Tests**: In-module `#[cfg(test)]` blocks. Test pure functions and
   business logic without external dependencies.

2. **Integration Tests**: In `tests/` directory. Test handlers and components with
   Docker services (Redis, MinIO). Use `axum::TestServer` or equivalent.

3. **E2E Tests**: In `tests/e2e/` directory. Test full deployment pipeline:
   - Deploy to Kind cluster via Kustomize/FluxCD
   - Verify Knative Service creation and routing
   - Test health endpoints, API endpoints, event flows

### Test Gates

- All tests MUST pass: `cargo test --all-features -- --ignored`
- Clippy MUST pass with strict warnings: `cargo clippy --all-targets --all-features
  -- -D warnings`
- Formatting MUST pass: `cargo fmt --all -- --check`

### Test Requirements in Features

When feature specifications explicitly request testing, use TDD:

1. Write tests FIRST
2. Ensure tests FAIL
3. Implement functionality
4. Verify tests PASS

If no testing requested in spec, tests are OPTIONAL but recommended for critical
paths.

## Governance

### Constitution Supremacy

This constitution supersedes all other development practices, style guides, and
conventions. In case of conflict, constitution governs.

### Amendment Process

Constitution amendments require:

1. **Proposal**: Document proposed changes with rationale in a Git issue or PR
2. **Review**: Technical review by maintainers
3. **Approval**: Merged by maintainer approval
4. **Version Bump**: Increment `CONSTITUTION_VERSION` according to semantic
   versioning:
   - **MAJOR**: Backward-incompatible governance/principle removals or redefinitions
   - **MINOR**: New principle/section added or materially expanded guidance
   - **PATCH**: Clarifications, wording, typo fixes, non-semantic refinements
5. **Migration Plan**: If MAJOR bump, include migration guide for existing code
6. **Date Update**: Update `LAST_AMENDED_DATE` to ISO format YYYY-MM-DD

### Compliance Review

All PRs MUST verify compliance with constitution:

- **Plan Phase**: Implementation plan must include "Constitution Check" section
  identifying any principle violations with justification
- **Code Review**: Reviewers must verify compliance with all principles
- **CI Gates**: Automated checks for formatting, clippy, and test coverage
- **Post-Merge**: Consider retrospectives for repeated violations

### Runtime Guidance

For day-to-day development guidance, refer to `AGENTS.md` which contains:
- Build, lint, and test commands
- Code style guidelines (expanded from this constitution)
- Testing patterns and examples
- Knative-specific constraints
- Configuration management details
- Commit message format

**Version**: 1.0.0 | **Ratified**: 2026-01-03 | **Last Amended**: 2026-01-03
