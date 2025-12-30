use axum::Json;
use axum_cloudevents::CloudEvent;
use serde::{Deserialize, Serialize};
use tracing::instrument;

#[derive(Debug, Deserialize)]
pub struct Ping {
    pub message: String,
}

#[derive(Debug, Serialize)]
pub struct Pong {
    pub reply: String,
    pub event_id: String,
}

#[instrument(
    skip(event),
    fields(
        event_id = %event.id(),
        event_type = %event.r#type(),
        source = %event.source(),
        message = %event.data.message
    )
)]
pub async fn handle_event(event: CloudEvent<Ping>) -> Json<Pong> {
    Json(Pong {
        reply: format!("pong: {}", event.data.message),
        event_id: event.id().to_string(),
    })
}
