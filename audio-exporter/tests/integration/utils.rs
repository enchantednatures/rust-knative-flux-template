//! Test utilities and fixtures for PostgreSQL integration tests

use sqlx::postgres::PgPool;
use std::env;

/// Build PostgreSQL connection string from environment variables
///
/// # Environment Variables
///
/// - `POSTGRES_URL`: Full connection string (takes precedence)
/// - `POSTGRES_HOST`: Hostname (default: postgres-test-postgres-rw.postgres-test.svc.cluster.local)
/// - `POSTGRES_PORT`: Port (default: 5432)
/// - `POSTGRES_USER`: Username (default: app)
/// - `POSTGRES_PASSWORD`: Password (required if not in POSTGRES_URL)
/// - `POSTGRES_DB`: Database name (default: app)
pub fn build_connection_string() -> Result<String, String> {
    // Check for full URL first
    if let Ok(url) = env::var("POSTGRES_URL") {
        return Ok(url);
    }

    // Fall back to individual parameters
    let host = env::var("POSTGRES_HOST")
        .unwrap_or_else(|_| "postgres-test-postgres-rw.postgres-test.svc.cluster.local".to_string());
    let port = env::var("POSTGRES_PORT").unwrap_or_else(|_| "5432".to_string());
    let user = env::var("POSTGRES_USER").unwrap_or_else(|_| "app".to_string());
    let password = env::var("POSTGRES_PASSWORD")
        .map_err(|_| "POSTGRES_PASSWORD environment variable is required".to_string())?;
    let db = env::var("POSTGRES_DB").unwrap_or_else(|_| "app".to_string());

    let url = format!("postgres://{}:{}@{}:{}/{}", user, password, host, port, db);
    Ok(url)
}

/// Create a connection pool for testing
///
/// Includes retry logic with exponential backoff for transient failures.
pub async fn create_test_pool() -> Result<PgPool, Box<dyn std::error::Error>> {
    use sqlx::postgres::PgPoolOptions;
    use std::time::Duration;

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
                return Ok(pool);
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

/// Setup test schema with common tables
pub async fn setup_test_schema(pool: &PgPool) -> Result<(), sqlx::Error> {
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
    .execute(pool)
    .await?;

    // Create indexes for performance
    sqlx::query("CREATE INDEX IF NOT EXISTS idx_test_records_name ON test_records(name)")
        .execute(pool)
        .await?;

    sqlx::query("CREATE INDEX IF NOT EXISTS idx_test_records_created ON test_records(created_at)")
        .execute(pool)
        .await?;

    eprintln!("✓ Test schema created");
    Ok(())
}

/// Clean up test data (truncate tables)
pub async fn cleanup_test_data(pool: &PgPool) -> Result<(), sqlx::Error> {
    sqlx::query("TRUNCATE TABLE test_records CASCADE")
        .execute(pool)
        .await?;
    eprintln!("✓ Test data cleaned up");
    Ok(())
}

/// Drop test schema
pub async fn drop_test_schema(pool: &PgPool) -> Result<(), sqlx::Error> {
    sqlx::query("DROP TABLE IF EXISTS test_records CASCADE")
        .execute(pool)
        .await?;
    eprintln!("✓ Test schema dropped");
    Ok(())
}
