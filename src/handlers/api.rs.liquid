use axum::{Json, extract::State};
use serde::{Deserialize, Serialize};
use tracing::instrument;
use utoipa::ToSchema;

use crate::state::AppState;
{%- if "kafka" in features %}
use std::sync::Arc;
{%- endif %}

#[derive(Serialize, ToSchema)]
pub struct HelloResponse {
    pub message: String,
    pub version: String,
}

#[derive(Deserialize, ToSchema)]
pub struct HelloQuery {
    pub name: Option<String>,
}

/// Hello endpoint - example API handler
///
/// Demonstrates:
/// - Versioned API route (/api/v1/hello)
/// - State access
/// - OpenAPI documentation
/// - Tracing (automatic via tower-http)
#[utoipa::path(
    get,
    path = "/api/v1/hello",
    tag = "API",
    params(
        ("name" = Option<String>, Query, description = "Name to greet")
    ),
    responses(
        (status = 200, description = "Success", body = HelloResponse)
    )
)]
#[instrument(level = "debug", skip(_state, query))]
pub async fn hello(
    State(_state): State<AppState>,
    axum::extract::Query(query): axum::extract::Query<HelloQuery>,
) -> Json<HelloResponse> {
    let name = query.name.unwrap_or_else(|| "World".into());

    {%- if "kafka" in features %}
    // Publish event to Kafka asynchronously (non-blocking)
    if let Some(publisher) = &_state.kafka_publisher {
        let publisher = Arc::clone(publisher);
        let broker_url = publisher.config.broker_url.clone();
        let topic = publisher.config.topic.clone();
        
        tokio::spawn(async move {
            let event = crate::handlers::kafka::create_dummy_event(
                &publisher.config,
                "/api/v1/hello"
            );
            let event_id = event.id().to_string();
            
            match publisher.publish(&event).await {
                Ok((partition, offset)) => {
                    tracing::debug!(
                        event_id = %event_id,
                        partition = partition,
                        offset = offset,
                        "Event published to Kafka"
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
    }
    {%- endif %}

    Json(HelloResponse {
        message: format!("Hello, {}!", name),
        version: env!("CARGO_PKG_VERSION").into(),
    })
}
