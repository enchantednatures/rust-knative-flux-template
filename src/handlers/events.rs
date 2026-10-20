{%- if feature_cron %}
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use axum_cloudevents::CloudEvent;
use serde::{Deserialize, Serialize};
use tracing::{info, instrument};

/// Event type emitted by Knative PingSource. It is fixed by Knative and is not
/// configurable, so scheduled dispatch keys off this constant alone.
const SCHEDULED_EVENT_TYPE: &str = "dev.knative.sources.ping";

#[derive(Debug, Deserialize)]
pub struct Ping {
    pub message: String,
}

#[derive(Debug, Serialize)]
pub struct Pong {
    pub reply: String,
    pub event_id: String,
}

#[derive(Debug, Serialize)]
pub struct ScheduledAck {
    pub received: bool,
    pub event_id: String,
}

#[instrument(
    skip(event),
    fields(
        event_id = %event.id(),
        event_type = %event.r#type(),
        source = %event.source(),
        payload = ?event.data
    )
)]
pub async fn handle_event(event: CloudEvent<serde_json::Value>) -> Response {
    if event.r#type() == SCHEDULED_EVENT_TYPE {
        return handle_scheduled_event(event).await;
    }

    let event_id = event.id().to_string();
    match serde_json::from_value::<Ping>(event.data) {
        Ok(ping) => Json(Pong {
            reply: format!("pong: {}", ping.message),
            event_id,
        })
        .into_response(),
        Err(_) => (StatusCode::BAD_REQUEST, "Invalid ping event payload").into_response(),
    }
}

#[instrument(
    skip(event),
    fields(
        event_id = %event.id(),
        event_type = %event.r#type(),
        source = %event.source(),
        payload = ?event.data
    )
)]
async fn handle_scheduled_event(event: CloudEvent<serde_json::Value>) -> Response {
    info!(
        event_id = %event.id(),
        event_type = %event.r#type(),
        source = %event.source(),
        payload = ?event.data,
        "Received scheduled CloudEvent"
    );

    Json(ScheduledAck {
        received: true,
        event_id: event.id().to_string(),
    })
    .into_response()
}
{%- else %}
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
{%- endif %}
