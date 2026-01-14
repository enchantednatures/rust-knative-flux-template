//! S3-compatible storage integration tests
//!
//! These tests require MinIO running locally:
//! ```bash
//! docker-compose up -d minio
//! ```
//!
//! Run with:
//! ```bash
//! cargo test --test storage_test -- --ignored --nocapture --test-threads=1
//! ```

use opendal::Operator;
use uuid::Uuid;

/// Check if a key exists in operator
async fn key_exists(op: &Operator, key: &str) -> bool {
    op.stat(key).await.is_ok()
}

/// Create a test operator pointing to local MinIO
///
/// Note: Each operator creates its own HTTP client. When running tests in parallel,
/// there can be interference between tests. Run with --test-threads=1 for reliability.
fn create_test_operator() -> Operator {
    let builder = opendal::services::S3::default()
        .endpoint("http://localhost:9000")
        .bucket("data")
        .region("us-east-1")
        .access_key_id("minioadmin")
        .secret_access_key("minioadmin");

    Operator::new(builder).unwrap().finish()
}

#[tokio::test]
#[ignore = "requires MinIO running (docker-compose up -d minio)"]
async fn test_write_and_read() {
    let op = create_test_operator();
    let key = format!("test/{}.txt", Uuid::new_v4());
    let content = b"hello from integration test";

    op.write(&key, content.to_vec()).await.unwrap();
    let data = op.read(&key).await.unwrap();
    assert_eq!(data.to_vec(), content.to_vec());
    op.delete(&key).await.unwrap();
}

#[tokio::test]
#[ignore = "requires MinIO running (docker-compose up -d minio)"]
async fn test_stat() {
    let op = create_test_operator();
    let key = format!("test/{}.txt", Uuid::new_v4());

    op.write(&key, b"test content".to_vec()).await.unwrap();
    let meta = op.stat(&key).await.unwrap();
    assert_eq!(meta.content_length(), 12);
    op.delete(&key).await.unwrap();
}

#[tokio::test]
#[ignore = "requires MinIO running (docker-compose up -d minio)"]
async fn test_list() {
    let op = create_test_operator();
    let prefix = format!("test-list-{}/", Uuid::new_v4());

    for i in 0..3 {
        op.write(&format!("{}{}.txt", prefix, i), b"content".to_vec())
            .await
            .unwrap();
    }

    let entries = op.list(&prefix).await.unwrap();
    assert_eq!(entries.len(), 3);

    for i in 0..3 {
        op.delete(&format!("{}{}.txt", prefix, i)).await.unwrap();
    }
}

#[tokio::test]
#[ignore = "requires MinIO running (docker-compose up -d minio)"]
async fn test_delete() {
    let op = create_test_operator();
    let key = format!("test/{}.txt", Uuid::new_v4());

    op.write(&key, b"temporary content".to_vec()).await.unwrap();
    assert!(key_exists(&op, &key).await);
    op.delete(&key).await.unwrap();
    assert!(!key_exists(&op, &key).await);
}
