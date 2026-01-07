# Phase 0 Research: Idempotency Guard Technical Decisions

**Created**: 2026-01-06  
**Status**: Complete  
**Purpose**: Resolve all technical unknowns before design phase

## 1. Redis vs PostgreSQL Atomic Operations

### Redis Implementation: SET NX EX

**Command**: `SET key value NX EX seconds`

**Semantics**:
- `NX`: Only set if key does NOT exist (atomic check-and-set)
- `EX`: Set TTL in seconds (automatic expiration)
- Returns: `1` if acquired, `null` if key already exists

**Pros**:
- Single atomic operation (no race conditions)
- Automatic TTL management by Redis (passive expiration)
- O(1) time complexity
- Simple implementation (one command)
- Handles crash recovery automatically (TTL expires, lock released)

**Cons**:
- Passive expiration may delay lock release by up to several seconds
- Memory overhead for Redis (all keys in memory)
- Requires Redis cluster for HA (additional infrastructure)

**Performance**: ~10-20ms latency typical, scales to 100k+ ops/sec on single instance

### PostgreSQL Implementation Options

#### Option A: Advisory Locks

```sql
SELECT pg_try_advisory_lock(hashtext('idempotency:event-123'));
-- Returns true if acquired, false if already held
-- Automatically released on connection close
```

**Pros**:
- Built-in PostgreSQL feature (no schema changes)
- Automatic release on connection close (crash safety)
- Very fast (in-memory operation)

**Cons**:
- No built-in TTL (requires background cleanup or manual timeout)
- Advisory locks persist until connection closes (long-lived connections problematic)
- Lock ID is int64 (requires hashing idempotency key)
- Harder to debug (locks not visible in normal tables)

#### Option B: Row-Level Locks with INSERT ON CONFLICT (RECOMMENDED)

```sql
CREATE TABLE idempotency_records (
    key VARCHAR(255) PRIMARY KEY,
    status VARCHAR(20) NOT NULL CHECK (status IN ('processing', 'completed')),
    acquired_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL
);

-- Acquire lock
INSERT INTO idempotency_records (key, status, expires_at)
VALUES ($1, 'processing', NOW() + INTERVAL '5 minutes')
ON CONFLICT (key) DO NOTHING
RETURNING key;
-- Returns row if acquired, empty if duplicate

-- Background cleanup (scheduled job)
DELETE FROM idempotency_records WHERE expires_at < NOW();
```

**Pros**:
- Visible in table (easy debugging and monitoring)
- TTL via expires_at column (explicit expiration time)
- Can query status and timestamps
- Works with connection pooling (not tied to connection lifetime)
- Standard SQL (portable)

**Cons**:
- Requires schema migration
- Needs background cleanup job for TTL expiration
- Slightly slower than advisory locks (~5-10ms vs ~2ms)

**Performance**: ~15-30ms latency typical, scales to 10k+ ops/sec

### Decision Matrix

| Criteria | Redis SET NX | PostgreSQL Advisory | PostgreSQL Row-Level |
|----------|--------------|---------------------|---------------------|
| Atomicity | ✅ Excellent | ✅ Excellent | ✅ Excellent |
| TTL Support | ✅ Automatic | ❌ Manual | ⚠️ Background job |
| Crash Safety | ✅ TTL expiration | ✅ Connection close | ✅ TTL via cleanup |
| Debuggability | ⚠️ Redis CLI | ❌ Hidden locks | ✅ Table queries |
| Performance | ✅ 10-20ms | ✅ 2-5ms | ⚠️ 15-30ms |
| Infrastructure | ⚠️ Requires Redis | ✅ Uses existing DB | ✅ Uses existing DB |
| Complexity | ✅ Simple | ⚠️ Medium | ⚠️ Medium |

### **DECISION**: 
- **Redis**: Use `SET NX EX` for simplicity and automatic TTL
- **PostgreSQL**: Use row-level locks (Option B) for debuggability and connection pool compatibility
- Both implementations satisfy atomicity and crash safety requirements

---

## 2. TTL Expiration Strategies

### Redis TTL Behavior

**Passive Expiration**: Redis does not expire keys immediately upon TTL reaching zero. Keys are expired:
1. When accessed (lazy expiration)
2. Via background process (active expiration, runs every 100ms, samples random keys)

**Implication**: A lock may remain in Redis for up to several seconds after TTL expires, blocking retries

**Safety Margin**: Add 5-10 second buffer to TTL to account for passive expiration delays
- If max event processing time is 5 minutes, set TTL to 305-310 seconds

### PostgreSQL TTL Behavior

**Manual Cleanup**: PostgreSQL has no built-in TTL. Two strategies:

#### Strategy A: Background Cleanup Job (RECOMMENDED)
```sql
-- Run every 30 seconds via pg_cron or external scheduler
DELETE FROM idempotency_records WHERE expires_at < NOW();
```

**Pros**: Simple, works with any PostgreSQL version
**Cons**: Cleanup granularity limited by job frequency (30-60 second delays possible)

#### Strategy B: Application-Level Check
```rust
// Check expires_at before treating as duplicate
if record.expires_at < Utc::now() {
    // Expired, delete and retry acquire
    DELETE FROM idempotency_records WHERE key = $1 AND expires_at < NOW();
    // Retry INSERT
}
```

**Pros**: Immediate cleanup, no background job needed
**Cons**: Extra query on every duplicate check

### Edge Case: TTL Expires Mid-Processing

**Scenario**: Event processing takes 5 minutes, but TTL is set to 4 minutes. TTL expires while still processing.

**Risk**: Retry arrives, acquires new lock, processes duplicate event

**Mitigation**:
1. Set TTL to maximum expected processing time + safety margin (e.g., 2x expected time)
2. Monitor `idempotency_latency_seconds` to detect slow processing
3. Alert if processing time approaches TTL threshold
4. Document: "TTL should be at least 2x your P99 event processing time"

### **DECISION**:
- **Redis**: Use passive expiration, add 10-second safety margin to configured TTL
- **PostgreSQL**: Use background cleanup job (every 30 seconds) + application-level expiration check on duplicates
- **TTL Configuration**: Default 300 seconds (5 minutes), minimum 60 seconds, maximum 3600 seconds (1 hour)
- **Safety Guidance**: Document "TTL should be 2x P99 processing time"

---

## 3. Concurrent Access Patterns

### Race Condition Scenarios

#### Scenario 1: Simultaneous Acquire Attempts

**Timeline**:
```
T0: Instance A checks key (not exists)
T1: Instance B checks key (not exists)
T2: Instance A sets key
T3: Instance B sets key (fails due to NX)
```

**Outcome**: Only one instance acquires lock (guaranteed by atomic NX operation)
**Verdict**: ✅ Safe (no duplicate processing)

#### Scenario 2: Acquire During Expiration Window

**Timeline** (Redis):
```
T0: Key exists with TTL=1s
T1: TTL expires (but Redis hasn't cleaned up yet)
T2: Instance A attempts SET NX (succeeds, key was lazily deleted)
T3: Instance B attempts SET NX (fails, key now exists)
```

**Outcome**: Only one instance acquires lock (atomic operation prevents race)
**Verdict**: ✅ Safe

**Timeline** (PostgreSQL):
```
T0: Row exists with expires_at = T0
T1: Instance A checks expires_at < NOW() (true)
T2: Instance B checks expires_at < NOW() (true)
T3: Instance A deletes row
T4: Instance B deletes row (no-op, already deleted)
T5: Instance A inserts row (succeeds)
T6: Instance B inserts row (fails, conflict)
```

**Outcome**: Only one instance acquires lock (INSERT ON CONFLICT is atomic)
**Verdict**: ✅ Safe

#### Scenario 3: Processing Complete During Duplicate Check

**Timeline**:
```
T0: Instance A acquires lock, starts processing
T1: Instance B checks for duplicate (finds "processing")
T2: Instance A completes, marks as "completed"
T3: Instance B returns 409 Duplicate response
```

**Outcome**: Duplicate correctly rejected
**Verdict**: ✅ Safe

### Retry Logic and Backoff

**Question**: Should the idempotency guard retry on storage failures?

**Answer**: NO - Fail fast and return error to caller

**Rationale**:
- Storage failures indicate infrastructure issues (network partition, backend down)
- Retrying at guard level adds latency and complexity
- Caller (event delivery system) is better positioned to retry entire request with backoff
- Allows circuit breaker pattern at higher level

**Error Response**:
- `IdempotencyError::StorageUnavailable` → HTTP 503 Service Unavailable
- Include `Retry-After` header (e.g., 60 seconds)
- Log with full context for alerting

### **DECISION**:
- **No retries** within idempotency guard (fail fast)
- Return `StorageUnavailable` error with 503 status code
- Document: "Callers should implement exponential backoff on 503 responses"
- Test scenarios:
  - 2+ instances acquiring same key simultaneously
  - Acquire during TTL expiration window
  - Backend unavailable during acquire
  - 1000 concurrent acquires on different keys

---

## 4. PostgreSQL Advisory Lock Alternatives

### Comparison of PostgreSQL Locking Mechanisms

| Mechanism | Atomicity | TTL Support | Debuggability | Connection Pool Safe | Complexity |
|-----------|-----------|-------------|---------------|---------------------|------------|
| Advisory Locks | ✅ Atomic | ❌ No | ❌ Low | ❌ No (connection-tied) | Low |
| Row Locks (INSERT ON CONFLICT) | ✅ Atomic | ⚠️ Manual | ✅ High | ✅ Yes | Medium |
| Serializable Transactions | ✅ Atomic | ❌ No | ⚠️ Medium | ✅ Yes | High |

### Advisory Locks Analysis

**Code Example**:
```rust
// Acquire
let acquired: bool = sqlx::query_scalar(
    "SELECT pg_try_advisory_lock(hashtext($1))"
)
.bind(format!("idempotency:{}", key))
.fetch_one(&pool)
.await?;

// Problem: Lock persists until connection returned to pool
// Solution: pg_advisory_unlock() before returning connection
// BUT: If process crashes, connection never returned → lock stuck
```

**Verdict**: ❌ REJECTED - Not safe with connection pooling and crash scenarios

### Row-Level Locks (INSERT ON CONFLICT) - RECOMMENDED

**Schema**:
```sql
CREATE TABLE idempotency_records (
    key VARCHAR(255) PRIMARY KEY,
    status VARCHAR(20) NOT NULL CHECK (status IN ('processing', 'completed')),
    acquired_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    instance_id VARCHAR(255), -- Optional: track which instance holds lock
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_expires_at ON idempotency_records(expires_at) 
WHERE expires_at < NOW() + INTERVAL '1 hour';
```

**Operations**:

```rust
// Acquire
pub async fn acquire(&self, key: &str, ttl: Duration) -> Result<bool, Error> {
    let expires_at = Utc::now() + ttl;
    
    // First, cleanup any expired record for this key
    sqlx::query("DELETE FROM idempotency_records WHERE key = $1 AND expires_at < NOW()")
        .bind(key)
        .execute(&self.pool)
        .await?;
    
    // Then attempt insert
    let result = sqlx::query(
        "INSERT INTO idempotency_records (key, status, expires_at) 
         VALUES ($1, 'processing', $2) 
         ON CONFLICT (key) DO NOTHING 
         RETURNING key"
    )
    .bind(key)
    .bind(expires_at)
    .fetch_optional(&self.pool)
    .await?;
    
    Ok(result.is_some())
}

// Mark completed
pub async fn mark_completed(&self, key: &str) -> Result<(), Error> {
    sqlx::query(
        "UPDATE idempotency_records 
         SET status = 'completed' 
         WHERE key = $1"
    )
    .bind(key)
    .execute(&self.pool)
    .await?;
    
    Ok(())
}

// Background cleanup (separate process, every 30s)
pub async fn cleanup_expired(&self) -> Result<u64, Error> {
    let deleted = sqlx::query("DELETE FROM idempotency_records WHERE expires_at < NOW()")
        .execute(&self.pool)
        .await?
        .rows_affected();
    
    Ok(deleted)
}
```

**Verdict**: ✅ SELECTED - Safe, debuggable, works with connection pooling

### Serializable Transactions Analysis

**Code Example**:
```sql
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT * FROM idempotency_records WHERE key = $1 FOR UPDATE;
-- If not exists, insert
COMMIT;
```

**Pros**: Strongest consistency guarantees
**Cons**: Performance overhead, serialization conflicts under high concurrency, complex error handling

**Verdict**: ❌ REJECTED - Overkill for this use case, row-level locks sufficient

### **DECISION**: 
Use **row-level locks with INSERT ON CONFLICT** for PostgreSQL backend. Requires schema migration and background cleanup job.

---

## 5. Metrics and Observability Patterns

### Critical Metrics

#### Counter Metrics

```rust
// Total acquire attempts
metrics::counter!("idempotency_acquire_total", 
    "backend" => backend_name, 
    "result" => result  // "success", "duplicate", "error"
);

// Duplicates detected (by status)
metrics::counter!("idempotency_duplicates_total",
    "backend" => backend_name,
    "status" => status  // "processing", "completed"
);

// Storage errors
metrics::counter!("idempotency_errors_total",
    "backend" => backend_name,
    "error_type" => error_type  // "timeout", "unavailable", "unknown"
);

// Successful completions
metrics::counter!("idempotency_completions_total",
    "backend" => backend_name
);
```

#### Histogram Metrics

```rust
// Latency of acquire operation
metrics::histogram!("idempotency_acquire_latency_seconds",
    "backend" => backend_name
);

// Latency of mark_completed operation
metrics::histogram!("idempotency_complete_latency_seconds",
    "backend" => backend_name
);

// Time from acquire to completion
metrics::histogram!("idempotency_processing_duration_seconds",
    "backend" => backend_name
);
```

#### Gauge Metrics

```rust
// Current number of processing locks (PostgreSQL only, via query)
metrics::gauge!("idempotency_processing_locks",
    "backend" => "postgres"
);

// (Query: SELECT COUNT(*) FROM idempotency_records WHERE status = 'processing')
```

### Tracing Spans

```rust
#[tracing::instrument(
    skip(self),
    fields(
        idempotency_key = %key,
        backend = %self.backend_name(),
        ttl_seconds = %ttl.as_secs()
    ),
    err(Debug)
)]
pub async fn acquire(&self, key: &str, ttl: Duration) -> Result<ProcessingGuard, IdempotencyError> {
    // Implementation
}
```

**Span attributes**:
- `idempotency_key`: The key being checked
- `backend`: "redis" or "postgres"
- `ttl_seconds`: Configured TTL
- `result`: "acquired", "duplicate", or "error"
- `duplicate_status`: If duplicate, "processing" or "completed"

### Structured Logging

```rust
tracing::info!(
    idempotency_key = %key,
    backend = %backend,
    "Idempotency lock acquired"
);

tracing::warn!(
    idempotency_key = %key,
    backend = %backend,
    status = %status,
    "Duplicate event detected"
);

tracing::error!(
    error = %err,
    idempotency_key = %key,
    backend = %backend,
    "Failed to acquire idempotency lock"
);
```

### Alerting Rules (Prometheus)

```yaml
# High duplicate rate (may indicate retry storm)
- alert: HighIdempotencyDuplicateRate
  expr: rate(idempotency_duplicates_total[5m]) > 100
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "High idempotency duplicate rate detected"

# Storage errors
- alert: IdempotencyStorageErrors
  expr: rate(idempotency_errors_total{error_type="unavailable"}[5m]) > 10
  for: 2m
  labels:
    severity: critical
  annotations:
    summary: "Idempotency storage backend unavailable"

# Slow acquire operations
- alert: SlowIdempotencyAcquire
  expr: histogram_quantile(0.95, idempotency_acquire_latency_seconds) > 0.1
  for: 10m
  labels:
    severity: warning
  annotations:
    summary: "Idempotency acquire P95 latency > 100ms"
```

### Dashboard Queries

```promql
# Success rate
sum(rate(idempotency_acquire_total{result="success"}[5m])) 
/ 
sum(rate(idempotency_acquire_total[5m]))

# Duplicate rate by status
sum by (status) (rate(idempotency_duplicates_total[5m]))

# P95 latency by backend
histogram_quantile(0.95, 
  sum by (le, backend) (rate(idempotency_acquire_latency_seconds_bucket[5m]))
)

# Active processing locks (PostgreSQL)
idempotency_processing_locks{backend="postgres"}
```

### **DECISION**:
Implement all metrics above with:
- Low cardinality labels (backend, result, status, error_type)
- Histogram buckets: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0]
- Tracing on all public async functions
- Structured logging for all state transitions

---

## Decision Summary

| Topic | Decision | Rationale |
|-------|----------|-----------|
| **Redis Implementation** | SET NX EX | Single atomic operation, automatic TTL, simple |
| **PostgreSQL Implementation** | Row-level locks (INSERT ON CONFLICT) | Debuggable, connection pool safe, explicit TTL |
| **TTL Strategy** | 2x P99 processing time + 10s safety margin | Prevents mid-processing expiration |
| **Concurrent Access** | Fail fast on storage errors, no retries | Let caller handle backoff and retries |
| **PostgreSQL Locking** | INSERT ON CONFLICT with cleanup job | Safe, visible, works with connection pooling |
| **Metrics** | Counters, histograms, gauges with low cardinality | Comprehensive observability, no explosion |

## Technical Risks Resolved

| Risk | Mitigation |
|------|------------|
| Clock skew | Document NTP requirement, use monotonic timestamps where possible |
| Passive expiration delays | Add 10-second safety margin to Redis TTL |
| PostgreSQL advisory lock leaks | Use row-level locks instead (not connection-tied) |
| Race conditions | Atomic operations (SET NX, INSERT ON CONFLICT) prevent races |
| TTL too short | Default to 2x expected processing time, monitor latency |

## Next Steps

Phase 0 research complete. All technical decisions resolved. Proceed to Phase 1:
1. Create data-model.md (IdempotencyRecord schema, state transitions)
2. Create contracts/ (OpenAPI error responses, headers)
3. Create quickstart.md (integration guide, configuration examples)
4. Update agent context
