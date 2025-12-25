use axum::Json;
use axum_cloudevents::CloudEvent;
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
pub struct Ping {
    pub message: String,
}

#[derive(Debug, Serialize)]
pub struct Pong {
    pub reply: String,
    pub event_id: String,
}

pub async fn handle_event(event: CloudEvent<Ping>) -> Json<Pong> {
    tracing::info!(
        event_id = %event.id(),
        event_type = %event.r#type(),
        source = %event.source(),
        message = %event.data.message,
        "Received CloudEvent",
    );

    Json(Pong {
        reply: format!("pong: {}", event.data.message),
        event_id: event.id().to_string(),
    })
}
