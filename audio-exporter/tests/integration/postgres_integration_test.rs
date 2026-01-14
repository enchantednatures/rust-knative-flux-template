//! PostgreSQL Integration Tests
//!
//! This test suite validates CRUD operations against a CloudNativePG test cluster.
//! Tests use sqlx for connection pooling and query execution.
//!
//! # Environment Variables
//!
//! - `POSTGRES_URL`: Full connection string (takes precedence)
//! - `POSTGRES_HOST`: Hostname (default: postgres-test-postgres-rw.postgres-test.svc.cluster.local)
//! - `POSTGRES_PORT`: Port (default: 5432)
//! - `POSTGRES_USER`: Username (default: app)
//! - `POSTGRES_PASSWORD`: Password (required if not in POSTGRES_URL)
//! - `POSTGRES_DB`: Database name (default: app)
//!
//! # Running Tests
//!
//! ```bash
//! # With environment variables
//! POSTGRES_HOST=localhost POSTGRES_PORT=5432 POSTGRES_USER=app POSTGRES_PASSWORD=password \
//!   cargo test --test postgres_integration_test -- --test-threads=1 --nocapture
//!
//! # Or with port-forward
//! kubectl port-forward svc/postgres-test-postgres-rw -n postgres-test 5432:5432 &
//! cargo test --test postgres_integration_test
//! ```

use sqlx::postgres::{PgPool, PgPoolOptions, PgQueryResult};
use sqlx::{Row, Error as SqlxError};
use std::env;
use std::time::Duration;

/// Test database connection pool
struct TestDb {
    pool: PgPool,
}

impl TestDb {
    /// Create a new test database connection pool
    ///
    /// Attempts to connect using environment variables or defaults.
    /// Implements exponential backoff retry logic for transient failures.
    async fn connect() -> Result<Self, Box<dyn std::error::Error>> {
        let url = build_connection_string()?;
        
        // Retry logic: 3 attempts with exponential backoff
        let mut attempts = 0;
        let max_attempts = 3;
        let mut base_delay_ms = 100;
        
        loop {
            match PgPoolOptions::new()
                .max_connections(5)
                .connect(&url)
                .await
            {
                Ok(pool) => {
                    eprintln!("✓ Connected to PostgreSQL");
                    return Ok(TestDb { pool });
                }
                Err(e) if attempts < max_attempts - 1 => {
                    attempts += 1;
                    let delay = Duration::from_millis(base_delay_ms);
                    eprintln!(
                        "✗ Connection attempt {} failed: {}, retrying in {}ms...",
                        attempts, e, base_delay_ms
                    );
                    tokio::time::sleep(delay).await;
                    base_delay_ms *= 2; // Exponential backoff
                }
                Err(e) => {
                    eprintln!("✗ Failed to connect after {} attempts: {}", max_attempts, e);
                    return Err(format!("PostgreSQL connection failed: {}", e).into());
                }
            }
        }
    }

    /// Create test schema and tables
    async fn setup_schema(&self) -> Result<(), SqlxError> {
        // Create test table with various data types
        sqlx::query(
            r#"
            CREATE TABLE IF NOT EXISTS test_records (
                id BIGSERIAL PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT,
                count INTEGER DEFAULT 0,
                is_active BOOLEAN DEFAULT true,
                metadata JSONB,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
            "#,
        )
        .execute(&self.pool)
        .await?;

        // Create indexes for performance
        sqlx::query("CREATE INDEX IF NOT EXISTS idx_test_records_name ON test_records(name)")
            .execute(&self.pool)
            .await?;

        sqlx::query("CREATE INDEX IF NOT EXISTS idx_test_records_created ON test_records(created_at)")
            .execute(&self.pool)
            .await?;

        eprintln!("✓ Test schema created");
        Ok(())
    }

    /// Clean up test data
    async fn cleanup(&self) -> Result<(), SqlxError> {
        sqlx::query("TRUNCATE TABLE test_records CASCADE")
            .execute(&self.pool)
            .await?;
        eprintln!("✓ Test data cleaned up");
        Ok(())
    }

    /// Drop test schema
    async fn drop_schema(&self) -> Result<(), SqlxError> {
        sqlx::query("DROP TABLE IF EXISTS test_records CASCADE")
            .execute(&self.pool)
            .await?;
        eprintln!("✓ Test schema dropped");
        Ok(())
    }
}

/// Build PostgreSQL connection string from environment variables
fn build_connection_string() -> Result<String, Box<dyn std::error::Error>> {
    // Check for full URL first
    if let Ok(url) = env::var("POSTGRES_URL") {
        return Ok(url);
    }

    // Fall back to individual parameters
    let host = env::var("POSTGRES_HOST")
        .unwrap_or_else(|_| "postgres-test-postgres-rw.postgres-test.svc.cluster.local".to_string());
    let port = env::var("POSTGRES_PORT").unwrap_or_else(|_| "5432".to_string());
    let user = env::var("POSTGRES_USER").unwrap_or_else(|_| "app".to_string());
    let password = env::var("POSTGRES_PASSWORD")?;
    let db = env::var("POSTGRES_DB").unwrap_or_else(|_| "app".to_string());

    let url = format!("postgres://{}:{}@{}:{}/{}", user, password, host, port, db);
    Ok(url)
}

// ============================================================================
// CRUD Tests
// ============================================================================

#[tokio::test]
async fn test_insert_basic_record() {
    let db = TestDb::connect().await.expect("Failed to connect to database");
    db.setup_schema().await.expect("Failed to setup schema");

    // Insert a basic record
    let result = sqlx::query(
        r#"
        INSERT INTO test_records (name, description, count, is_active)
        VALUES ($1, $2, $3, $4)
        RETURNING id
        "#,
    )
    .bind("test_record_1")
    .bind("A test record")
    .bind(42)
    .bind(true)
    .fetch_one(&db.pool)
    .await
    .expect("Failed to insert record");

    let id: i64 = result.get("id");
    assert!(id > 0, "Expected positive ID, got {}", id);
    eprintln!("✓ Inserted record with ID: {}", id);

    db.cleanup().await.expect("Failed to cleanup");
    db.drop_schema().await.expect("Failed to drop schema");
}

#[tokio::test]
async fn test_insert_with_json_metadata() {
    let db = TestDb::connect().await.expect("Failed to connect to database");
    db.setup_schema().await.expect("Failed to setup schema");

    // Insert record with JSONB metadata
    let metadata = serde_json::json!({
        "version": "1.0",
        "tags": ["test", "integration"],
        "priority": 5
    });

    let result = sqlx::query(
        r#"
        INSERT INTO test_records (name, description, metadata, is_active)
        VALUES ($1, $2, $3, $4)
        RETURNING id, metadata
        "#,
    )
    .bind("json_test_record")
    .bind("Record with JSON metadata")
    .bind(metadata)
    .bind(true)
    .fetch_one(&db.pool)
    .await
    .expect("Failed to insert record with metadata");

    let id: i64 = result.get("id");
    let stored_metadata: serde_json::Value = result.get("metadata");
    
    assert_eq!(stored_metadata["version"], "1.0");
    assert_eq!(stored_metadata["priority"], 5);
    eprintln!("✓ Inserted record with JSON metadata: {}", id);

    db.cleanup().await.expect("Failed to cleanup");
    db.drop_schema().await.expect("Failed to drop schema");
}

#[tokio::test]
async fn test_insert_multiple_records() {
    let db = TestDb::connect().await.expect("Failed to connect to database");
    db.setup_schema().await.expect("Failed to setup schema");

    // Insert multiple records in a transaction
    let mut tx = db.pool.begin().await.expect("Failed to start transaction");

    for i in 0..10 {
        sqlx::query(
            r#"
            INSERT INTO test_records (name, description, count)
            VALUES ($1, $2, $3)
            "#,
        )
        .bind(format!("record_{}", i))
        .bind(format!("Description for record {}", i))
        .bind(i as i32)
        .execute(&mut *tx)
        .await
        .expect(&format!("Failed to insert record {}", i));
    }

    tx.commit().await.expect("Failed to commit transaction");
    eprintln!("✓ Inserted 10 records in transaction");

    // Verify count
    let count: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM test_records")
        .fetch_one(&db.pool)
        .await
        .expect("Failed to count records");

    assert_eq!(count.0, 10, "Expected 10 records, found {}", count.0);

    db.cleanup().await.expect("Failed to cleanup");
    db.drop_schema().await.expect("Failed to drop schema");
}

#[tokio::test]
async fn test_select_by_id() {
    let db = TestDb::connect().await.expect("Failed to connect to database");
    db.setup_schema().await.expect("Failed to setup schema");

    // Insert a record
    let result = sqlx::query(
        r#"
        INSERT INTO test_records (name, description, count)
        VALUES ('select_test', 'Test record for selection', 99)
        RETURNING id
        "#,
    )
    .fetch_one(&db.pool)
    .await
    .expect("Failed to insert record");

    let inserted_id: i64 = result.get("id");

    // Select by ID
    let row = sqlx::query(
        r#"
        SELECT id, name, description, count, is_active
        FROM test_records
        WHERE id = $1
        "#,
    )
    .bind(inserted_id)
    .fetch_one(&db.pool)
    .await
    .expect("Failed to select record by ID");

    let id: i64 = row.get("id");
    let name: String = row.get("name");
    let count: i32 = row.get("count");
    let is_active: bool = row.get("is_active");

    assert_eq!(id, inserted_id);
    assert_eq!(name, "select_test");
    assert_eq!(count, 99);
    assert!(is_active);
    eprintln!("✓ Selected record by ID: {} (name: {})", id, name);

    db.cleanup().await.expect("Failed to cleanup");
    db.drop_schema().await.expect("Failed to drop schema");
}

#[tokio::test]
async fn test_select_with_filtering() {
    let db = TestDb::connect().await.expect("Failed to connect to database");
    db.setup_schema().await.expect("Failed to setup schema");

    // Insert multiple records with different count values
    for i in 0..5 {
        sqlx::query(
            r#"
            INSERT INTO test_records (name, count, is_active)
            VALUES ($1, $2, $3)
            "#,
        )
        .bind(format!("record_{}", i))
        .bind(i * 10)
        .bind(i % 2 == 0) // alternate active/inactive
        .execute(&db.pool)
        .await
        .expect(&format!("Failed to insert record {}", i));
    }

    // Select active records with count > 15
    let rows = sqlx::query(
        r#"
        SELECT id, name, count
        FROM test_records
        WHERE is_active = true AND count > 15
        ORDER BY count DESC
        "#,
    )
    .fetch_all(&db.pool)
    .await
    .expect("Failed to fetch filtered records");

    assert_eq!(rows.len(), 2, "Expected 2 active records with count > 15");

    for row in rows {
        let id: i64 = row.get("id");
        let count: i32 = row.get("count");
        assert!(count > 15);
        eprintln!("✓ Found record {} with count {}", id, count);
    }

    db.cleanup().await.expect("Failed to cleanup");
    db.drop_schema().await.expect("Failed to drop schema");
}

#[tokio::test]
async fn test_select_range_query() {
    let db = TestDb::connect().await.expect("Failed to connect to database");
    db.setup_schema().await.expect("Failed to setup schema");

    // Insert records with timestamps
    for i in 0..5 {
        sqlx::query(
            r#"
            INSERT INTO test_records (name, count)
            VALUES ($1, $2)
            "#,
        )
        .bind(format!("range_record_{}", i))
        .bind(i as i32)
        .execute(&db.pool)
        .await
        .expect(&format!("Failed to insert record {}", i));
    }

    // Select records created in the last hour
    let rows = sqlx::query("SELECT id, name FROM test_records WHERE created_at > NOW() - INTERVAL '1 hour'")
        .fetch_all(&db.pool)
        .await
        .expect("Failed to fetch records by timestamp range");

    assert_eq!(rows.len(), 5, "Expected 5 recent records");
    eprintln!("✓ Range query returned {} records", rows.len());

    db.cleanup().await.expect("Failed to cleanup");
    db.drop_schema().await.expect("Failed to drop schema");
}

#[tokio::test]
async fn test_update_single_field() {
    let db = TestDb::connect().await.expect("Failed to connect to database");
    db.setup_schema().await.expect("Failed to setup schema");

    // Insert a record
    let result = sqlx::query(
        r#"
        INSERT INTO test_records (name, count, is_active)
        VALUES ('update_test', 10, true)
        RETURNING id
        "#,
    )
    .fetch_one(&db.pool)
    .await
    .expect("Failed to insert record");

    let id: i64 = result.get("id");

    // Update the count field
    sqlx::query(
        r#"
        UPDATE test_records
        SET count = $1, updated_at = CURRENT_TIMESTAMP
        WHERE id = $2
        "#,
    )
    .bind(20)
    .bind(id)
    .execute(&db.pool)
    .await
    .expect("Failed to update record");

    // Verify the update
    let row = sqlx::query("SELECT count FROM test_records WHERE id = $1")
        .bind(id)
        .fetch_one(&db.pool)
        .await
        .expect("Failed to fetch updated record");

    let count: i32 = row.get("count");
    assert_eq!(count, 20, "Expected count to be 20, got {}", count);
    eprintln!("✓ Updated record: count = {}", count);

    db.cleanup().await.expect("Failed to cleanup");
    db.drop_schema().await.expect("Failed to drop schema");
}

#[tokio::test]
async fn test_update_multiple_fields() {
    let db = TestDb::connect().await.expect("Failed to connect to database");
    db.setup_schema().await.expect("Failed to setup schema");

    // Insert a record
    let result = sqlx::query(
        r#"
        INSERT INTO test_records (name, description, is_active)
        VALUES ('multi_update_test', 'Original description', true)
        RETURNING id
        "#,
    )
    .fetch_one(&db.pool)
    .await
    .expect("Failed to insert record");

    let id: i64 = result.get("id");

    // Update multiple fields
    sqlx::query(
        r#"
        UPDATE test_records
        SET description = $1, is_active = $2, count = $3, updated_at = CURRENT_TIMESTAMP
        WHERE id = $4
        "#,
    )
    .bind("Updated description")
    .bind(false)
    .bind(99)
    .bind(id)
    .execute(&db.pool)
    .await
    .expect("Failed to update record");

    // Verify all updates
    let row = sqlx::query(
        "SELECT description, is_active, count FROM test_records WHERE id = $1"
    )
    .bind(id)
    .fetch_one(&db.pool)
    .await
    .expect("Failed to fetch updated record");

    let description: String = row.get("description");
    let is_active: bool = row.get("is_active");
    let count: i32 = row.get("count");

    assert_eq!(description, "Updated description");
    assert!(!is_active);
    assert_eq!(count, 99);
    eprintln!("✓ Updated multiple fields successfully");

    db.cleanup().await.expect("Failed to cleanup");
    db.drop_schema().await.expect("Failed to drop schema");
}

#[tokio::test]
async fn test_update_with_json() {
    let db = TestDb::connect().await.expect("Failed to connect to database");
    db.setup_schema().await.expect("Failed to setup schema");

    let initial_metadata = serde_json::json!({
        "status": "initial",
        "version": 1
    });

    // Insert a record with metadata
    let result = sqlx::query(
        r#"
        INSERT INTO test_records (name, metadata)
        VALUES ('json_update_test', $1)
        RETURNING id
        "#,
    )
    .bind(initial_metadata)
    .fetch_one(&db.pool)
    .await
    .expect("Failed to insert record");

    let id: i64 = result.get("id");

    // Update the JSON metadata
    let updated_metadata = serde_json::json!({
        "status": "updated",
        "version": 2,
        "timestamp": "2026-01-03T00:00:00Z"
    });

    sqlx::query(
        r#"
        UPDATE test_records
        SET metadata = $1, updated_at = CURRENT_TIMESTAMP
        WHERE id = $2
        "#,
    )
    .bind(updated_metadata.clone())
    .bind(id)
    .execute(&db.pool)
    .await
    .expect("Failed to update record");

    // Verify the JSON update
    let row = sqlx::query("SELECT metadata FROM test_records WHERE id = $1")
        .bind(id)
        .fetch_one(&db.pool)
        .await
        .expect("Failed to fetch updated record");

    let metadata: serde_json::Value = row.get("metadata");
    assert_eq!(metadata["status"], "updated");
    assert_eq!(metadata["version"], 2);
    eprintln!("✓ Updated JSON metadata successfully");

    db.cleanup().await.expect("Failed to cleanup");
    db.drop_schema().await.expect("Failed to drop schema");
}

#[tokio::test]
async fn test_delete_single_record() {
    let db = TestDb::connect().await.expect("Failed to connect to database");
    db.setup_schema().await.expect("Failed to setup schema");

    // Insert a record
    let result = sqlx::query(
        r#"
        INSERT INTO test_records (name, description)
        VALUES ('delete_test', 'Record to be deleted')
        RETURNING id
        "#,
    )
    .fetch_one(&db.pool)
    .await
    .expect("Failed to insert record");

    let id: i64 = result.get("id");

    // Delete the record
    let delete_result = sqlx::query("DELETE FROM test_records WHERE id = $1")
        .bind(id)
        .execute(&db.pool)
        .await
        .expect("Failed to delete record");

    assert_eq!(delete_result.rows_affected(), 1);

    // Verify deletion
    let count: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM test_records WHERE id = $1")
        .bind(id)
        .fetch_one(&db.pool)
        .await
        .expect("Failed to count records");

    assert_eq!(count.0, 0, "Expected record to be deleted");
    eprintln!("✓ Deleted record: {}", id);

    db.cleanup().await.expect("Failed to cleanup");
    db.drop_schema().await.expect("Failed to drop schema");
}

#[tokio::test]
async fn test_delete_multiple_records() {
    let db = TestDb::connect().await.expect("Failed to connect to database");
    db.setup_schema().await.expect("Failed to setup schema");

    // Insert multiple records
    for i in 0..5 {
        sqlx::query(
            r#"
            INSERT INTO test_records (name, count, is_active)
            VALUES ($1, $2, $3)
            "#,
        )
        .bind(format!("delete_record_{}", i))
        .bind(i as i32)
        .bind(i % 2 == 0)
        .execute(&db.pool)
        .await
        .expect(&format!("Failed to insert record {}", i));
    }

    // Delete inactive records
    let delete_result = sqlx::query("DELETE FROM test_records WHERE is_active = false")
        .execute(&db.pool)
        .await
        .expect("Failed to delete inactive records");

    assert_eq!(delete_result.rows_affected(), 2, "Expected to delete 2 inactive records");

    // Verify deletion
    let count: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM test_records")
        .fetch_one(&db.pool)
        .await
        .expect("Failed to count records");

    assert_eq!(count.0, 3, "Expected 3 active records remaining");
    eprintln!("✓ Deleted 2 inactive records, {} remaining", count.0);

    db.cleanup().await.expect("Failed to cleanup");
    db.drop_schema().await.expect("Failed to drop schema");
}

// ============================================================================
// Error Handling Tests
// ============================================================================

#[tokio::test]
async fn test_connection_error_handling() {
    // Attempt to connect with invalid credentials
    let invalid_url = "postgres://invalid:invalid@localhost:9999/nonexistent";
    
    let result = PgPoolOptions::new()
        .max_connections(5)
        .connect(invalid_url)
        .await;

    assert!(result.is_err(), "Expected connection to fail with invalid credentials");
    eprintln!("✓ Connection error handled gracefully");
}

#[tokio::test]
async fn test_constraint_violation() {
    let db = TestDb::connect().await.expect("Failed to connect to database");
    db.setup_schema().await.expect("Failed to setup schema");

    // Insert a record
    sqlx::query(
        r#"
        INSERT INTO test_records (name, description)
        VALUES ('constraint_test', 'Original description')
        "#,
    )
    .execute(&db.pool)
    .await
    .expect("Failed to insert record");

    // Attempt to insert with NULL name (should fail due to NOT NULL constraint)
    let result = sqlx::query(
        r#"
        INSERT INTO test_records (description)
        VALUES ('No name provided')
        "#,
    )
    .execute(&db.pool)
    .await;

    assert!(result.is_err(), "Expected constraint violation error");
    eprintln!("✓ Constraint violation error handled");

    db.cleanup().await.expect("Failed to cleanup");
    db.drop_schema().await.expect("Failed to drop schema");
}

#[tokio::test]
async fn test_transaction_rollback_on_error() {
    let db = TestDb::connect().await.expect("Failed to connect to database");
    db.setup_schema().await.expect("Failed to setup schema");

    let mut tx = db.pool.begin().await.expect("Failed to start transaction");

    // Insert first record
    sqlx::query(
        r#"
        INSERT INTO test_records (name, description)
        VALUES ('tx_record_1', 'First record')
        "#,
    )
    .execute(&mut *tx)
    .await
    .expect("Failed to insert first record");

    // Attempt to insert invalid record (NULL name)
    let result = sqlx::query(
        r#"
        INSERT INTO test_records (description)
        VALUES ('Second record without name')
        "#,
    )
    .execute(&mut *tx)
    .await;

    assert!(result.is_err(), "Expected constraint violation");

    // Rollback the transaction
    tx.rollback().await.expect("Failed to rollback transaction");

    // Verify that no records were inserted
    let count: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM test_records")
        .fetch_one(&db.pool)
        .await
        .expect("Failed to count records");

    assert_eq!(count.0, 0, "Expected no records after rollback");
    eprintln!("✓ Transaction rollback on error successful");

    db.cleanup().await.expect("Failed to cleanup");
    db.drop_schema().await.expect("Failed to drop schema");
}
