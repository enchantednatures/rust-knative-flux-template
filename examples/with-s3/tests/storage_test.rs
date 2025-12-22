
//! S3-compatible storage integration tests
//! 
//! These tests require MinIO running locally:
//! ```bash
//! docker-compose up -d minio
//! ```
//!
//! Run with:
//! ```bash
//! cargo test --test storage_test -- --ignored --nocapture
//! ```

use opendal::Operator;
use uuid::Uuid;

/// Create a test operator pointing to local MinIO
fn create_test_operator() -> Operator {
    let builder = opendal::services::S3::default()
        .endpoint("http://localhost:9000")
        .bucket("data")
        .region("us-east-1");
    
    // MinIO credentials from environment or defaults
    std::env::set_var("AWS_ACCESS_KEY_ID", "minioadmin");
    std::env::set_var("AWS_SECRET_ACCESS_KEY", "minioadmin");
    
    Operator::new(builder).unwrap().finish()
}

#[tokio::test]
#[ignore = "requires MinIO running (docker-compose up -d minio)"]
async fn test_write_and_read() {
    let op = create_test_operator();
    let key = format!("test/{}.txt", Uuid::new_v4());
    let content = b"hello from integration test";
    
    // Write
    op.write(&key, content.to_vec()).await.unwrap();
    
    // Read back
    let data = op.read(&key).await.unwrap();
    assert_eq!(data.to_vec(), content.to_vec());
    
    // Cleanup
    op.delete(&key).await.unwrap();
}

#[tokio::test]
#[ignore = "requires MinIO running (docker-compose up -d minio)"]
async fn test_stat() {
    let op = create_test_operator();
    let key = format!("test/{}.txt", Uuid::new_v4());
    
    // Write first
    op.write(&key, b"test content".to_vec()).await.unwrap();
    
    // Stat
    let meta = op.stat(&key).await.unwrap();
    assert_eq!(meta.content_length(), 12);
    
    // Cleanup
    op.delete(&key).await.unwrap();
}

#[tokio::test]
#[ignore = "requires MinIO running (docker-compose up -d minio)"]
async fn test_list() {
    let op = create_test_operator();
    let prefix = format!("test-list-{}/", Uuid::new_v4());
    
    // Write a few files
    for i in 0..3 {
        op.write(&format!("{}{}.txt", prefix, i), b"content".to_vec())
            .await
            .unwrap();
    }
    
    // List
    let entries: Vec<_> = op.list(&prefix).await.unwrap().collect().await;
    assert_eq!(entries.len(), 3);
    
    // Cleanup
    for i in 0..3 {
        op.delete(&format!("{}{}.txt", prefix, i)).await.unwrap();
    }
}

#[tokio::test]
#[ignore = "requires MinIO running (docker-compose up -d minio)"]
async fn test_delete() {
    let op = create_test_operator();
    let key = format!("test/{}.txt", Uuid::new_v4());
    
    // Write
    op.write(&key, b"temporary content".to_vec())
        .await
        .unwrap();
    
    // Verify exists
    assert!(op.is_exist(&key).await.unwrap());
    
    // Delete
    op.delete(&key).await.unwrap();
    
    // Verify deleted
    assert!(!op.is_exist(&key).await.unwrap());
}

