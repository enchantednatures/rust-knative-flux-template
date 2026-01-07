# Data Model: Idempotency Guard

**Created**: 2026-01-06  
**Status**: Complete  
**Purpose**: Define entities, relationships, and state transitions for idempotency tracking

## Entity Definitions

### 1. IdempotencyKey

**Purpose**: Unique identifier for an event, used to track processing status

**Type**: String (newtype wrapper)

**Constraints**:
- Maximum length: 255 characters
- Minimum length: 1 character (non-empty)
- Character set: UTF-8 encoded, printable characters recommended
- Case-sensitive

**Source**:
- Extracted from CloudEvent header `ce-id` (preferred)
- Or from HTTP header `Idempotency-Key`
- Or from event payload field (configurable)

**Validation Rules**:
```rust
fn validate_idempotency_key(key: &str) -> Result<(), ValidationError> {
    if key.is_empty() {
        return Err(ValidationError::Empty);
    }
    if key.len() > 255 {
        return Err(ValidationError::TooLong);
    }
    // Optional: validate character set (alphanumeric + hyphens/underscores)
    Ok(())
}
```

**Examples**:
- Good: `event-2026-01-06-abc123`, `order-payment-12345`, `user-signup-uuid-v4`
- Bad: `` (empty), `a`.repeat(256) (too long)

---

### 2. IdempotencyRecord

**Purpose**: Stored representation of event processing state in Redis or PostgreSQL

**Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `key` | String (255) | Yes | Idempotency key (primary identifier) |
| `status` | Enum | Yes | Current processing status |
| `acquired_at` | Timestamp | Yes | When lock was first acquired (ISO 8601) |
| `expires_at` | Timestamp | Yes | When lock expires (acquired_at + TTL) |
| `instance_id` | String (100) | No | Instance that acquired lock (for debugging) |
| `created_at` | Timestamp | Yes | Record creation timestamp (immutable) |

**Status Enum**:
```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IdempotencyStatus {
    /// Event is currently being processed
    Processing,
    /// Event processing completed successfully
    Completed,
}
```

**Storage Representations**:

#### Redis Storage

```
Key: "idempotency:{key}"
Value: JSON-encoded status info
TTL: Automatic via EX parameter

Example:
Key: idempotency:event-12345
Value: {"status":"processing","acquired_at":"2026-01-06T12:00:00Z","instance_id":"pod-abc"}
TTL: 300 seconds
```

#### PostgreSQL Storage

```sql
CREATE TABLE idempotency_records (
    key VARCHAR(255) PRIMARY KEY,
    status VARCHAR(20) NOT NULL CHECK (status IN ('processing', 'completed')),
    acquired_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    instance_id VARCHAR(100),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_expires_at ON idempotency_records(expires_at) 
WHERE expires_at < NOW() + INTERVAL '1 hour';
```

**Indexes**:
- Primary key on `key` (for fast lookup)
- Index on `expires_at` (for cleanup query efficiency)

---

### 3. ProcessingGuard

**Purpose**: RAII wrapper ensuring idempotency lock cleanup on drop

**Type**: Rust struct (not persisted)

**Fields**:
```rust
pub struct ProcessingGuard {
    /// The idempotency key being guarded
    key: String,
    /// Reference to storage backend for cleanup
    store: Arc<IdempotencyStore>,
    /// When lock was acquired (for metrics)
    acquired_at: Instant,
}
```

**Lifetime**:
- Created: When `IdempotencyGuard::acquire()` succeeds
- Held: For duration of event processing
- Dropped: When processing completes or panics

**Drop Behavior**:
```rust
impl Drop for ProcessingGuard {
    fn drop(&mut self) {
        // Mark as completed in background (don't block drop)
        let key = self.key.clone();
        let store = Arc::clone(&self.store);
        
        tokio::spawn(async move {
            if let Err(e) = store.mark_completed(&key).await {
                tracing::warn!(
                    error = %e,
                    idempotency_key = %key,
                    "Failed to mark idempotency record as completed"
                );
            }
        });
    }
}
```

**Safety Notes**:
- Drop is called even during panics (Rust guarantee)
- If mark_completed fails, TTL will eventually clean up lock
- Metrics track processing duration from acquire to drop

---

### 4. IdempotencyStore (Trait)

**Purpose**: Abstraction over storage backends (Redis, PostgreSQL)

**Trait Definition**:
```rust
#[async_trait]
pub trait IdempotencyStoreBackend: Send + Sync {
    /// Attempt to acquire an idempotency lock
    /// Returns Ok(true) if acquired, Ok(false) if duplicate
    async fn acquire(&self, key: &str, ttl: Duration) -> Result<bool, IdempotencyError>;
    
    /// Mark an idempotency key as completed
    async fn mark_completed(&self, key: &str) -> Result<(), IdempotencyError>;
    
    /// Check status of an idempotency key (for debugging)
    async fn check_status(&self, key: &str) -> Result<Option<IdempotencyStatus>, IdempotencyError>;
    
    /// Backend name for logging/metrics
    fn backend_name(&self) -> &'static str;
}
```

**Implementations**:
- `RedisStore`: Implements trait using Redis commands
- `PostgresStore`: Implements trait using PostgreSQL queries

**Enum Wrapper**:
```rust
pub enum IdempotencyStore {
    Redis(RedisStore),
    Postgres(PostgresStore),
}

impl IdempotencyStore {
    pub async fn acquire(&self, key: &str, ttl: Duration) -> Result<bool, IdempotencyError> {
        match self {
            Self::Redis(store) => store.acquire(key, ttl).await,
            Self::Postgres(store) => store.acquire(key, ttl).await,
        }
    }
    // ... similar delegation for other methods
}
```

---

## State Transitions

### State Diagram

```
                   +------------------+
                   |   No Record      |
                   |  (key not found) |
                   +------------------+
                            |
                            | acquire() → success
                            v
                   +------------------+
              +--->|   Processing     |
              |    +------------------+
              |             |
              |             | mark_completed()
              |             v
              |    +------------------+
              |    |    Completed     |
              |    +------------------+
              |             |
              |             | TTL expires
              |             v
              |    +------------------+
              +----|   No Record      |
                   +------------------+
                            ^
                            | TTL expires
                            |
                   +------------------+
                   |   Processing     |
                   | (crash scenario) |
                   +------------------+
```

### State Transition Table

| Current State | Event | Next State | Action | Notes |
|---------------|-------|------------|--------|-------|
| No Record | acquire() | Processing | Create record, return guard | Happy path |
| Processing | acquire() | Processing | Return error | Duplicate detected |
| Completed | acquire() | Completed | Return error | Already processed |
| Processing | TTL expires | No Record | Cleanup record | Allows retry after crash |
| Completed | TTL expires | No Record | Cleanup record | Free up storage |
| Processing | mark_completed() | Completed | Update status | Normal completion |
| No Record | mark_completed() | No Record | No-op (log warning) | Race: TTL expired |

### Transition Invariants

1. **Atomicity**: State transitions are atomic at storage level
   - Redis: SET NX ensures only one process creates "Processing" record
   - PostgreSQL: INSERT ON CONFLICT ensures only one process creates record

2. **Monotonicity**: Once "Completed", record never returns to "Processing" (until TTL expires)

3. **Crash Safety**: If process crashes in "Processing" state, TTL expiration returns to "No Record"

4. **Idempotency**: Multiple calls to `mark_completed()` are safe (idempotent operation)

---

## Relationships and Dependencies

### Entity Relationship Diagram

```
┌──────────────────┐
│ IdempotencyKey   │
│ (String)         │
└────────┬─────────┘
         │ identifies
         │
         v
┌──────────────────┐       stored in      ┌──────────────────┐
│IdempotencyRecord │<─────────────────────│ IdempotencyStore │
│                  │                      │  (Redis/PG)      │
└────────┬─────────┘                      └──────────────────┘
         │ guards
         │
         v
┌──────────────────┐
│ ProcessingGuard  │
│  (RAII wrapper)  │
└──────────────────┘
```

### Dependencies

**IdempotencyKey**:
- No dependencies (primitive type wrapper)

**IdempotencyRecord**:
- Depends on: IdempotencyKey, IdempotencyStatus

**ProcessingGuard**:
- Depends on: IdempotencyKey, IdempotencyStore
- Holds reference to store for cleanup

**IdempotencyStore**:
- Depends on: Redis connection manager OR PostgreSQL connection pool
- Abstracted via trait (no direct dependency on either)

---

## Validation Rules

### Key Validation

```rust
impl IdempotencyKey {
    pub fn new(key: String) -> Result<Self, ValidationError> {
        if key.is_empty() {
            return Err(ValidationError::Empty);
        }
        if key.len() > 255 {
            return Err(ValidationError::TooLong { max: 255, actual: key.len() });
        }
        Ok(Self(key))
    }
}
```

### TTL Validation

```rust
pub fn validate_ttl(ttl: Duration) -> Result<(), ValidationError> {
    const MIN_TTL: Duration = Duration::from_secs(60);
    const MAX_TTL: Duration = Duration::from_secs(3600);
    
    if ttl < MIN_TTL {
        return Err(ValidationError::TtlTooShort { min: MIN_TTL, actual: ttl });
    }
    if ttl > MAX_TTL {
        return Err(ValidationError::TtlTooLong { max: MAX_TTL, actual: ttl });
    }
    Ok(())
}
```

### Status Validation

```rust
impl IdempotencyStatus {
    pub fn from_str(s: &str) -> Result<Self, ValidationError> {
        match s {
            "processing" => Ok(Self::Processing),
            "completed" => Ok(Self::Completed),
            _ => Err(ValidationError::InvalidStatus { status: s.to_string() }),
        }
    }
}
```

---

## Storage Size Estimates

### Redis

**Per Record**:
- Key: ~30 bytes (prefix + idempotency key)
- Value: ~150 bytes (JSON with status, timestamps)
- Overhead: ~50 bytes (Redis metadata)
- **Total**: ~230 bytes per record

**For 100,000 concurrent processing events**:
- 230 bytes × 100,000 = 23 MB

**For 1,000,000 events/day with 5-minute average TTL**:
- Steady state: ~3,500 concurrent events
- Memory: ~0.8 MB

### PostgreSQL

**Per Record**:
- Row: ~200 bytes (columns + overhead)
- Index: ~40 bytes (primary key + expires_at index)
- **Total**: ~240 bytes per record

**For 100,000 concurrent processing events**:
- 240 bytes × 100,000 = 24 MB table size
- Plus indexes: ~4 MB
- **Total**: ~28 MB

**Cleanup Impact**:
- Background job deletes expired rows every 30s
- Postgres autovacuum reclaims space
- No significant bloat expected with proper TTL configuration

---

## Migration Considerations

### Adding PostgreSQL Support to Existing Deployments

1. **Create schema** (via SQL migration):
```sql
-- V001__create_idempotency_records.sql
CREATE TABLE IF NOT EXISTS idempotency_records (
    key VARCHAR(255) PRIMARY KEY,
    status VARCHAR(20) NOT NULL CHECK (status IN ('processing', 'completed')),
    acquired_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    instance_id VARCHAR(100),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_expires_at 
ON idempotency_records(expires_at) 
WHERE expires_at < NOW() + INTERVAL '1 hour';
```

2. **Configure backend** (via environment variable):
```bash
APP__IDEMPOTENCY__BACKEND=postgres  # or "redis"
```

3. **No data migration needed** (TTL-based, no long-term retention)

### Schema Evolution

**Adding instance_id field** (already optional in schema):
- No migration needed for Redis (JSON value structure flexible)
- ALTER TABLE for PostgreSQL (safe operation, nullable column)

**Increasing key length** (future-proofing):
- Redis: No schema, no migration
- PostgreSQL: ALTER TABLE change VARCHAR(255) → VARCHAR(500) (requires lock)

---

## Summary

**Entities Defined**: 4 (IdempotencyKey, IdempotencyRecord, ProcessingGuard, IdempotencyStore)  
**State Transitions**: 7 (documented with invariants)  
**Storage Backends**: 2 (Redis, PostgreSQL)  
**Validation Rules**: 3 (key, TTL, status)  
**Indexes Required**: 2 (primary key, expires_at)  

**Next Steps**: Create API contracts and integration guide
