# PostgreSQL Integration Tests

This directory contains integration tests for PostgreSQL database operations using the `sqlx` library.

## Overview

The integration tests validate CRUD (Create, Read, Update, Delete) operations against a CloudNativePG-managed PostgreSQL cluster. Tests are designed to run in both local development environments and CI/CD pipelines.

## Test Coverage

### CRUD Operations

#### INSERT Tests
- `test_insert_basic_record` - Insert a simple record and verify ID generation
- `test_insert_with_json_metadata` - Insert records with JSONB metadata
- `test_insert_multiple_records` - Insert multiple records in a single transaction

#### SELECT Tests
- `test_select_by_id` - Retrieve a record by primary key
- `test_select_with_filtering` - Query records with WHERE clauses
- `test_select_range_query` - Range queries using timestamp predicates

#### UPDATE Tests
- `test_update_single_field` - Update one column in a record
- `test_update_multiple_fields` - Update multiple columns atomically
- `test_update_with_json` - Update JSONB metadata fields

#### DELETE Tests
- `test_delete_single_record` - Delete a specific record
- `test_delete_multiple_records` - Delete records matching a condition

### Error Handling Tests

- `test_connection_error_handling` - Verify graceful handling of connection failures
- `test_constraint_violation` - Test database constraint error handling
- `test_transaction_rollback_on_error` - Verify transaction rollback on errors

## Running Tests

### Prerequisites

1. **PostgreSQL Cluster**: A CloudNativePG cluster must be running and accessible
   - For local development: Use Kind + CloudNativePG operator
   - For CI: Test setup handles cluster provisioning

2. **sqlx CLI** (optional, for offline mode):
   ```bash
   cargo install sqlx-cli
   ```

### Local Development

#### Option 1: Port-Forward (Simplest)

```bash
# In one terminal: start port-forward
kubectl port-forward svc/postgres-test-postgres-rw -n postgres-test 5432:5432

# In another terminal: run tests
cargo test --test postgres_integration_test -- --nocapture --test-threads=1
```

#### Option 2: Environment Variables

```bash
export POSTGRES_HOST=localhost
export POSTGRES_PORT=5432
export POSTGRES_USER=app
export POSTGRES_PASSWORD=<your-password>
export POSTGRES_DB=app

cargo test --test postgres_integration_test -- --nocapture --test-threads=1
```

#### Option 3: Full Connection URL

```bash
export POSTGRES_URL="postgres://app:password@localhost:5432/app"

cargo test --test postgres_integration_test -- --nocapture --test-threads=1
```

### CI/CD Environment

```bash
# Test setup handles cluster provisioning automatically
cargo test --test postgres_integration_test -- --test-threads=1 --nocapture
```

## Environment Variables

The test suite respects the following environment variables in order of precedence:

| Variable | Default | Purpose |
|----------|---------|---------|
| `POSTGRES_URL` | (none) | Full connection string (takes precedence over others) |
| `POSTGRES_HOST` | `postgres-test-postgres-rw.postgres-test.svc.cluster.local` | Hostname |
| `POSTGRES_PORT` | `5432` | Port number |
| `POSTGRES_USER` | `app` | Database user |
| `POSTGRES_PASSWORD` | (required if not in POSTGRES_URL) | User password |
| `POSTGRES_DB` | `app` | Database name |

## Test Execution Details

### Connection Pooling

- Tests use `sqlx::Pool<sqlx::Postgres>` with a maximum of 5 connections
- Connection pool is reused across tests for efficiency
- Pool is dropped after each test for cleanup

### Retry Logic

- Initial connection attempts include exponential backoff retry logic
- Up to 3 connection attempts with backoff delays (100ms, 200ms, 400ms)
- Useful for handling transient network issues during cluster startup

### Schema Management

Each test:
1. **Setup**: Creates test schema and tables
2. **Execution**: Runs CRUD operations
3. **Cleanup**: Truncates test data and drops schema

This isolation ensures tests don't interfere with each other.

### Transaction Handling

- Individual INSERT/SELECT/UPDATE/DELETE operations are auto-committed
- Multi-statement operations use explicit transactions with `BEGIN` and `COMMIT`
- Rollback tests verify transaction abort behavior

## Test Data Types

The test schema validates handling of various PostgreSQL data types:

- **TEXT**: String data
- **BIGINT**: Large integers with auto-increment
- **INTEGER**: 32-bit integers  
- **BOOLEAN**: True/false values
- **JSONB**: JSON binary format with indexing support
- **TIMESTAMP**: Date/time values (with automatic defaults)

## Performance Expectations

- Individual test execution: < 5 seconds each
- Full test suite: < 2 minutes (excluding initial cluster startup)
- Typical operations: < 100ms per query

## Troubleshooting

### Connection Refused

```
Error: Failed to connect to database: connection refused
```

**Solution**: Verify cluster is running and accessible
```bash
# Check cluster status
kubectl get cluster -n postgres-test

# Check service exists
kubectl get svc -n postgres-test | grep postgres

# Test port-forward
kubectl port-forward svc/postgres-test-postgres-rw -n postgres-test 5432:5432 &
psql -h localhost -U app -d app  # Should prompt for password
```

### Authentication Failed

```
Error: Failed to connect to database: role "app" does not exist
```

**Solution**: Verify credentials and cluster initialization
```bash
# Check cluster has been fully initialized
kubectl describe cluster postgres-test -n postgres-test

# Check PostgreSQL logs
kubectl logs postgres-test-1 -n postgres-test
```

### Timeout Issues

```
Error: Failed to connect after 3 attempts
```

**Solution**: Increase timeouts for slower environments
- Modify connection timeout in `TestDb::connect()` in postgres_integration_test.rs
- Default backoff: 100ms, 200ms, 400ms
- Maximum attempts: 3

## Implementation Notes

### Why sqlx?

- Compile-time checked queries (when using macro mode)
- Zero-copy deserialization for performance
- Native PostgreSQL types support (JSONB, arrays, ranges, etc.)
- Automatic connection pooling
- Support for transactions and savepoints
- No runtime reflection overhead

### Error Handling Pattern

Tests follow Rust error handling best practices:

```rust
// Using ? operator for propagation
let result = sqlx::query(...).fetch_one(&db.pool).await?;

// Using expect() with context messages
.expect("Failed to insert record")

// Using assertions for test validation
assert_eq!(id, expected_id);
```

### Concurrency Considerations

- Tests run sequentially (`--test-threads=1`) to avoid schema conflicts
- Schema is dropped after each test for isolation
- Connection pool is thread-safe and can handle concurrent connections

## Future Enhancements

Planned improvements to the test suite:

1. **Parameterized Tests**: Use test macros to reduce code duplication
2. **Fixtures**: Create shared test data sets
3. **Performance Tests**: Measure query latency and throughput
4. **Concurrent Load Tests**: Validate connection pooling under load
5. **Backup Integration**: Test restore operations against backups
6. **Point-in-Time Recovery**: Validate PITR functionality

## References

- [sqlx Documentation](https://github.com/launchbadge/sqlx)
- [CloudNativePG Documentation](https://cloudnative-pg.io/)
- [PostgreSQL Types](https://www.postgresql.org/docs/current/datatype.html)
