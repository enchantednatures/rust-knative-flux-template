{% if feature_s3 -%}
//! S3 storage example endpoint
//!
//! Demonstrates OpenDAL usage for S3 operations

use axum::{Json, extract::State, http::StatusCode};
use serde::{Deserialize, Serialize};
use tracing::instrument;
use utoipa::ToSchema;

use crate::{error::AppError, state::AppState};
{%- if feature_kafka %}
use std::sync::Arc;
{%- endif %}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, ToSchema)]
pub struct StorageTestData {
    pub message: String,
    pub timestamp: String,
    pub test_id: String,
}

#[derive(Serialize, ToSchema)]
pub struct StorageExampleResponse {
    pub success: bool,
    pub write_key: String,
    pub write_size: usize,
    pub read_verified: bool,
    pub data: StorageTestData,
}

/// Example S3 storage operation
///
/// Demonstrates a complete write/read cycle:
/// 1. Generates test data
/// 2. Writes JSON to S3
/// 3. Reads it back
/// 4. Verifies integrity
/// 5. Cleans up test file
#[utoipa::path(
    post,
    path = "/api/v1/storage/example",
    tag = "Storage",
    responses(
        (status = 200, description = "Storage operation successful", body = StorageExampleResponse),
        (status = 500, description = "Storage operation failed")
    )
)]
#[instrument(skip(state), fields(s3_key = tracing::field::Empty), err)]
pub async fn storage_example(
    State(state): State<AppState>,
) -> Result<(StatusCode, Json<StorageExampleResponse>), AppError> {
    // Generate test data
    let test_data = StorageTestData {
        message: "Hello from S3 storage!".to_string(),
        timestamp: chrono::Utc::now().to_rfc3339(),
        test_id: uuid::Uuid::new_v4().to_string(),
    };

    let key = format!("test/{}.json", test_data.test_id);
    tracing::Span::current().record("s3_key", key.as_str());
    let json_bytes = serde_json::to_vec(&test_data)
        .map_err(|e| AppError::Internal(format!("Serialization failed: {}", e)))?;
    let write_size = json_bytes.len();

    // Write to S3
    state
        .storage
        .write(&key, json_bytes)
        .await
        .map_err(|e| AppError::Internal(format!("S3 write failed: {}", e)))?;

    // Read back from S3
    let retrieved = state
        .storage
        .read(&key)
        .await
        .map_err(|e| AppError::Internal(format!("S3 read failed: {}", e)))?;

    let retrieved_data: StorageTestData = serde_json::from_slice(&retrieved.to_vec())
        .map_err(|e| AppError::Internal(format!("Deserialization failed: {}", e)))?;

    // Verify data integrity
    let verified = retrieved_data == test_data;

    tracing::debug!(
        key = %key,
        verified = verified,
        "Read test data from S3"
    );

    // Cleanup: delete test file
    state
        .storage
        .delete(&key)
        .await
        .map_err(|e| AppError::Internal(format!("S3 delete failed: {}", e)))?;

    tracing::debug!(key = %key, "Cleaned up test file");

    {%- if feature_kafka %}
    // Publish event to Kafka asynchronously (non-blocking)
    if let Some(publisher) = &state.kafka_publisher {
        let publisher = Arc::clone(publisher);
        let broker_url = publisher.config.broker_url.clone();
        let topic = publisher.config.topic.clone();
        
        tokio::spawn(async move {
            let event = crate::handlers::kafka::create_dummy_event(
                &publisher.config,
                "/api/v1/storage/example"
            );
            let event_id = event.id().to_string();
            
            match publisher.publish(&event).await {
                Ok((partition, offset)) => {
                    tracing::debug!(
                        event_id = %event_id,
                        partition = partition,
                        offset = offset,
                        "Storage operation event published to Kafka"
                    );
                }
                Err(e) => {
                    let (error_type, error_context) = e.context();
                    tracing::error!(
                        error = %e,
                        error_type = %error_type,
                        error_context = %error_context,
                        event_id = %event_id,
                        broker = %broker_url,
                        topic = %topic,
                        "Failed to publish storage operation event to Kafka"
                    );
                }
            }
        });
    }
    {%- endif %}

    Ok((
        StatusCode::OK,
        Json(StorageExampleResponse {
            success: true,
            write_key: key,
            write_size,
            read_verified: verified,
            data: retrieved_data,
        }),
    ))
}
{%- endif %}
