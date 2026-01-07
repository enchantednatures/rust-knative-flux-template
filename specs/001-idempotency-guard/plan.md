# Implementation Plan: Event Idempotency Guard

**Branch**: `001-idempotency-guard` | **Date**: 2026-01-06 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-idempotency-guard/spec.md`

**Note**: This template is filled in by the `/speckit.plan` command. See `.specify/templates/commands/plan.md` for the execution workflow.

## Summary

Implement an event idempotency guard system that prevents duplicate event processing through atomic lock acquisition with configurable TTL. The system will support both Redis (key-value) and PostgreSQL (relational database) backends, providing transparent backend switching via configuration. The guard uses a RAII pattern (ProcessingGuard) to automatically manage lock lifecycle, ensuring locks are released even during crashes via TTL expiration.

## Technical Context

**Language/Version**: Rust 1.92 (edition 2024)
**Primary Dependencies**: 
- axum 0.8 (web framework)
- redis 0.24 (Redis backend with connection manager)
- sqlx 0.8 (PostgreSQL backend with async support)
- thiserror 1.0 (error handling)
- tracing 0.1 (observability)
- tokio 1.41 (async runtime)

**Storage**: 
- Redis (key-value store) - using SET NX EX for atomic lock acquisition with TTL
- PostgreSQL (relational database) - using advisory locks or INSERT with ON CONFLICT for atomic operations

**Testing**: 
- Unit tests: `cargo test` for business logic
- Integration tests: `axum-test` for handler testing with mock backends
- E2E tests: Tests against real Redis and PostgreSQL instances in Docker

**Target Platform**: Knative on Kubernetes (Linux container, port 8080)

**Project Type**: Single Rust library/binary (existing template structure)

**Performance Goals**: 
- Idempotency check latency: <50ms P95
- Throughput: 1000+ concurrent checks per second
- Cold start: <2 seconds (Knative requirement)

**Constraints**: 
- Knative port 8080 requirement (already satisfied)
- TTL-based expiration (no long-term retention)
- Best-effort guarantees (storage failures handled gracefully)
- B3 header propagation for distributed tracing

**Scale/Scope**: 
- Support for high-volume event processing (1000+ events/sec)
- TTL range: 1 second to 1 hour (configurable)
- Idempotency key size: up to 255 characters

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### Mandatory Checks

- [x] **Observability**: All public async functions use `#[instrument]` macro; structured logging with tracing; metrics for all endpoints; B3 header propagation
  - Will instrument `IdempotencyGuard::acquire()`, `ProcessingGuard::drop()`, and backend implementations
  - Metrics: `idempotency_checks_total`, `idempotency_duplicates_total`, `idempotency_errors_total`, `idempotency_latency_seconds`
  - B3 propagation already handled by existing axum middleware

- [x] **Testing**: Unit tests for all modules (`#[cfg(test)]` blocks); integration tests in `tests/` directory; E2E tests for critical paths; `cargo test --all-features -- --ignored` passes
  - Unit tests for guard logic, TTL calculations, state transitions
  - Integration tests for Redis/PostgreSQL backends with Docker containers
  - E2E tests for concurrent access scenarios and crash recovery

- [x] **Configuration**: Follows three-tier hierarchy (env vars > environment.toml > default.toml); `APP__` prefix for env vars; secrets never in repository
  - `APP__IDEMPOTENCY__BACKEND` (redis|postgres)
  - `APP__IDEMPOTENCY__TTL_SECONDS` (default: 300)
  - `APP__IDEMPOTENCY__TIMEOUT_MS` (default: 10000)
  - Redis/PostgreSQL connection strings via existing config

- [x] **Error Handling**: Uses `thiserror` for custom errors; `?` operator for propagation; `IntoResponse` implemented; errors logged with context
  - New error types: `IdempotencyError::Duplicate`, `IdempotencyError::StorageUnavailable`, `IdempotencyError::Timeout`
  - `IntoResponse` implementation returns appropriate HTTP status codes (409 for duplicate, 503 for storage unavailable)

- [x] **Performance**: Cold start <2 seconds preferred; async/await for all I/O; connection pooling via AppState; port 8080 hardcoded
  - All storage operations are async
  - Redis connection manager and PostgreSQL connection pool managed via `AppState`
  - No blocking operations in critical path

- [x] **Knative Constraints**: `/health/live` and `/health/ready` endpoints implemented; SIGTERM handling with 30s grace; B3 propagation enabled; read-only root filesystem
  - Health endpoints already exist in template
  - Readiness check will verify idempotency backend connectivity
  - No filesystem writes required (all state in Redis/PostgreSQL)

### Complexity Tracking

No violations detected. All constitution principles are satisfied by the design.

## Project Structure

### Documentation (this feature)

```text
specs/001-idempotency-guard/
├── spec.md              # Feature specification (completed)
├── plan.md              # This file (/speckit.plan command output)
├── research.md          # Phase 0 output (backend comparison, TTL strategies)
├── data-model.md        # Phase 1 output (IdempotencyRecord schema)
├── quickstart.md        # Phase 1 output (integration guide)
├── contracts/           # Phase 1 output (API contract)
│   └── idempotency.yaml # OpenAPI specification for idempotency errors
└── tasks.md             # Phase 2 output (/speckit.tasks command - NOT created by /speckit.plan)
```

### Source Code (repository root)

```text
src/
├── idempotency/         # NEW: Idempotency guard module
│   ├── mod.rs           # Public API exports
│   ├── guard.rs         # IdempotencyGuard and ProcessingGuard
│   ├── store.rs         # IdempotencyStore trait and enum
│   ├── redis.rs         # Redis backend implementation
│   ├── postgres.rs      # PostgreSQL backend implementation
│   ├── config.rs        # Idempotency configuration
│   └── error.rs         # IdempotencyError types
├── handlers/
│   ├── events.rs        # MODIFIED: Add idempotency guard usage example
│   └── ...              # Existing handlers
├── config.rs.liquid     # MODIFIED: Add idempotency config section
├── state.rs.liquid      # MODIFIED: Add IdempotencyGuard to AppState
├── error.rs.liquid      # MODIFIED: Add IdempotencyError variant
└── ...                  # Existing template files

tests/
├── integration/
│   ├── idempotency_redis_test.rs      # NEW: Redis backend tests
│   ├── idempotency_postgres_test.rs   # NEW: PostgreSQL backend tests
│   └── idempotency_concurrent_test.rs # NEW: Concurrency and crash tests
└── ...                                # Existing tests

config/
├── default.toml         # MODIFIED: Add idempotency defaults
└── development.toml     # MODIFIED: Add dev-specific idempotency config
```

**Structure Decision**: Single project structure (Option 1) is appropriate since this is a library feature within the existing Rust template. The idempotency module will be added as a new top-level module under `src/idempotency/`, following the existing pattern of domain-based organization (`handlers/`, `observability/`, etc.).

## Phase 0: Research & Technical Decisions

### Research Tasks

The following unknowns from Technical Context require research before implementation:

1. **Redis vs PostgreSQL atomic operations**
   - Research: Compare Redis SET NX EX vs PostgreSQL advisory locks vs INSERT ON CONFLICT
   - Decision needed: Which provides better performance and semantics for idempotency?
   - Output: Recommendation for each backend's implementation strategy

2. **TTL expiration strategies**
   - Research: Active vs passive TTL expiration in Redis and PostgreSQL
   - Decision needed: How to handle edge cases where TTL expires mid-processing?
   - Output: TTL safety margin recommendations and cleanup patterns

3. **Concurrent access patterns**
   - Research: Race condition scenarios when multiple instances acquire same key simultaneously
   - Decision needed: Retry logic, backoff strategies, and error responses
   - Output: Concurrency control patterns and test scenarios

4. **PostgreSQL advisory lock alternatives**
   - Research: Advisory locks vs row-level locks vs serializable transactions
   - Decision needed: Best approach for PostgreSQL backend considering performance and correctness
   - Output: PostgreSQL implementation pattern with schema design

5. **Metrics and observability patterns**
   - Research: What metrics are critical for idempotency monitoring?
   - Decision needed: Metric names, labels, and cardinality considerations
   - Output: Comprehensive metrics specification

### Phase 0 Deliverables

**Output File**: `research.md` containing:
- Backend comparison matrix (Redis vs PostgreSQL performance, semantics, edge cases)
- TTL implementation strategies with safety recommendations
- Concurrency control patterns and test scenarios
- PostgreSQL schema design and lock strategy
- Observability specification (metrics, traces, logs)
- Decision log for all technical choices

## Phase 1: Design & Contracts

**Prerequisites**: `research.md` complete with all technical decisions resolved

### Data Model

**Output File**: `data-model.md`

Entities and their relationships:

1. **IdempotencyKey**
   - Type: String (max 255 characters)
   - Validation: Non-empty, UTF-8 encoded
   - Source: CloudEvent header or HTTP header

2. **IdempotencyRecord** (storage representation)
   - Fields:
     - `key`: String (primary identifier)
     - `status`: Enum (Processing | Completed)
     - `acquired_at`: Timestamp (ISO 8601)
     - `expires_at`: Timestamp (ISO 8601)
   - State transitions:
     - `null` → `Processing` (via acquire())
     - `Processing` → `Completed` (via guard drop on success)
     - `Processing` → `null` (via TTL expiration)
     - `Completed` → `null` (via TTL expiration)

3. **ProcessingGuard** (RAII wrapper)
   - Purpose: Ensure cleanup on drop (even during panics)
   - Holds: Reference to store, idempotency key, acquired timestamp
   - Drop behavior: Mark as completed or release lock

4. **IdempotencyStore** (trait + enum)
   - Trait methods:
     - `acquire(key, ttl) -> Result<bool, Error>`
     - `mark_completed(key) -> Result<(), Error>`
     - `check_status(key) -> Result<Option<Status>, Error>`
   - Implementations: RedisStore, PostgresStore

### API Contracts

**Output Directory**: `contracts/`

**File**: `contracts/idempotency-errors.yaml` (OpenAPI fragment)

```yaml
components:
  responses:
    DuplicateEvent:
      description: Event with this idempotency key is already processing or completed
      content:
        application/json:
          schema:
            type: object
            properties:
              error:
                type: string
                example: "Duplicate event"
              idempotency_key:
                type: string
              status:
                type: string
                enum: [processing, completed]
    
    IdempotencyStorageUnavailable:
      description: Idempotency storage backend unavailable
      content:
        application/json:
          schema:
            type: object
            properties:
              error:
                type: string
                example: "Idempotency storage unavailable"
              retry_after:
                type: integer
                description: Seconds to wait before retry
```

**File**: `contracts/idempotency-header.yaml` (OpenAPI fragment)

```yaml
components:
  parameters:
    IdempotencyKey:
      name: Idempotency-Key
      in: header
      required: true
      description: Unique identifier for event deduplication
      schema:
        type: string
        maxLength: 255
        example: "event-12345-abc"
```

### Integration Guide

**Output File**: `quickstart.md`

Contents:
1. How to add idempotency guard to existing handlers
2. Configuration examples (Redis and PostgreSQL)
3. Testing with duplicate events
4. Monitoring and metrics dashboard examples
5. Troubleshooting common issues (TTL too short, backend unavailable)

### Agent Context Update

After Phase 1 design artifacts are complete, update agent context:

```bash
.specify/scripts/bash/update-agent-context.sh opencode
```

This will add to `AGENTS.md`:
- Idempotency guard usage patterns
- Configuration for Redis/PostgreSQL backends
- Testing patterns for idempotency scenarios

## Phase 2: Task Breakdown (Out of Scope for /speckit.plan)

**Note**: Task breakdown will be generated by `/speckit.tasks` command after Phase 1 design is complete. This plan stops at Phase 1 completion.

Expected task categories:
1. Core implementation (guard, stores, config)
2. Backend implementations (Redis, PostgreSQL)
3. Integration with existing handlers
4. Testing infrastructure (unit, integration, E2E)
5. Documentation and examples
6. Metrics and observability

## Risks and Mitigations

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Clock skew causes TTL miscalculations | Medium | Low | Use monotonic timestamps where possible; document NTP requirement |
| Storage backend unavailable causes event loss | High | Medium | Return 503 errors; implement circuit breaker pattern; document retry expectations |
| Race conditions on concurrent access | High | Medium | Comprehensive testing; use atomic operations; document behavior |
| TTL too short causes false duplicates | Medium | Low | Configurable TTL; monitoring for expired-while-processing scenarios |
| PostgreSQL advisory locks held indefinitely | Medium | Low | Connection timeout enforcement; health check to detect stuck locks |

## Success Metrics

Tracking alignment with success criteria from spec.md:

- **SC-001**: Zero duplicates within TTL - Validated by concurrent E2E tests
- **SC-002**: <50ms P95 latency - Monitored via `idempotency_latency_seconds` metric
- **SC-003**: 1000+ ops/sec - Load tested in integration tests
- **SC-004**: TTL expiration <5sec - Validated by crash recovery tests
- **SC-005**: Retry after crash - Validated by TTL expiration tests
- **SC-006**: Zero duplicates in production - Monitored via `idempotency_duplicates_total` metric
- **SC-007**: Backend switching via config - Validated by integration tests with both backends

## Next Steps

After this plan is approved:

1. Execute Phase 0: Create `research.md` by researching technical unknowns
2. Execute Phase 1: Create `data-model.md`, `contracts/`, and `quickstart.md`
3. Update agent context via script
4. Run `/speckit.tasks` to generate implementation task breakdown

**Estimated Effort**: 
- Phase 0 Research: 2-4 hours
- Phase 1 Design: 3-4 hours
- Phase 2 Implementation: 12-16 hours (estimated, will be refined in tasks.md)
