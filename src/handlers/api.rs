use axum::{Json, extract::State};
use serde::{Deserialize, Serialize};
use tracing::instrument;
use utoipa::ToSchema;
use validator::Validate;

use crate::state::AppState;
{%- if feature_kafka %}
use std::sync::Arc;
{%- endif %}

#[derive(Serialize, ToSchema)]
pub struct HelloResponse {
    pub message: String,
    pub version: String,
    pub request_id: Option<String>,
}

#[derive(Deserialize, ToSchema, Validate)]
pub struct HelloQuery {
    #[validate(length(
        min = 1,
        max = 100,
        message = "Name must be between 1 and 100 characters"
    ))]
    #[validate(regex(
        path = "*crate::handlers::validation::SAFE_NAME_REGEX",
        message = "Name contains invalid characters"
    ))]
    pub name: Option<String>,
}

/// Hello endpoint - example API handler
///
/// Demonstrates:
/// - Versioned API route (/api/v1/hello)
/// - State access
/// - OpenAPI documentation
/// - Tracing with contextual fields
/// - Input validation
#[utoipa::path(
    get,
    path = "/api/v1/hello",
    tag = "API",
    params(
        ("name" = Option<String>, Query, description = "Name to greet (1-100 characters, alphanumeric only)")
    ),
    responses(
        (status = 200, description = "Success", body = HelloResponse),
        (status = 400, description = "Invalid input", body = crate::error::ValidationErrorResponse)
    )
)]
#[instrument(
    level = "debug",
    skip(_state, query),
    fields(
        handler = "hello",
        name = ?query.name,
        has_kafka_publisher = {%- if feature_kafka %}true{%- else %}false{%- endif %}
    )
)]
pub async fn hello(
    State(_state): State<AppState>,
    axum::extract::Query(query): axum::extract::Query<HelloQuery>,
) -> Result<Json<HelloResponse>, crate::error::AppError> {
    // Validate input
    if let Err(validation_errors) = query.validate() {
        tracing::warn!(
            validation_errors = %validation_errors,
            "Input validation failed"
        );
        return Err(crate::error::AppError::Validation(
            validation_errors.to_string(),
        ));
    }

    let name = query.name.unwrap_or_else(|| "World".into());

    tracing::info!(
        name = %name,
        "Processing hello request"
    );

    {%- if feature_kafka %}
    // Publish event to Kafka asynchronously (non-blocking)
    if let Some(publisher) = &_state.kafka_publisher {
        let publisher = Arc::clone(publisher);
        let broker_url = publisher.config.broker_url.clone();
        let topic = publisher.config.topic.clone();
        let event_name = publisher.config.event_name.clone();

        tokio::spawn(async move {
            let event =
                crate::handlers::kafka::create_dummy_event(&publisher.config, "/api/v1/hello");
            let event_id = event.id().to_string();

            tracing::debug!(
                event_id = %event_id,
                event_type = %event_name,
                broker = %broker_url,
                topic = %topic,
                "Publishing event to Kafka"
            );

            match publisher.publish(&event).await {
                Ok((partition, offset)) => {
                    tracing::info!(
                        event_id = %event_id,
                        partition = partition,
                        offset = offset,
                        topic = %topic,
                        latency_ms = 0, // Would track actual latency
                        "Event published to Kafka successfully"
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
                        "Failed to publish event to Kafka"
                    );
                }
            }
        });
    } else {
        tracing::debug!("Kafka publisher not configured, skipping event publication");
    }
    {%- endif %}

    let response = HelloResponse {
        message: format!("Hello, {}!", name),
        version: env!("CARGO_PKG_VERSION").into(),
        request_id: None, // Will be populated by middleware
    };

    tracing::info!(
        name = %name,
        version = %response.version,
        "Hello request completed successfully"
    );

    Ok(Json(response))
}
