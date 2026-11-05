{%- if feature_cron or feature_bucket_notifications %}
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use axum_cloudevents::CloudEvent;
use serde::{Deserialize, Serialize};
use tracing::{info, instrument};

{% if feature_cron %}
/// Event type emitted by Knative PingSource. It is fixed by Knative and is not
/// configurable, so scheduled dispatch keys off this constant alone.
const SCHEDULED_EVENT_TYPE: &str = "dev.knative.sources.ping";
{% endif %}

#[derive(Debug, Deserialize)]
pub struct Ping {
    pub message: String,
}

#[derive(Debug, Serialize)]
pub struct Pong {
    pub reply: String,
    pub event_id: String,
}

{% if feature_cron %}
#[derive(Debug, Serialize)]
pub struct ScheduledAck {
    pub received: bool,
    pub event_id: String,
}
{% endif %}

{% if feature_s3 and feature_bucket_notifications %}
#[derive(Debug, Serialize)]
pub struct BucketNotificationAck {
    pub received: bool,
    pub event_id: String,
    pub records: usize,
}
{% endif %}

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
{% if feature_cron %}
    if event.r#type() == SCHEDULED_EVENT_TYPE {
        return handle_scheduled_event(event).await;
    }
{% endif %}
{% if feature_s3 and feature_bucket_notifications %}
    // Ceph RGW publishes S3 notifications as a JSON document with a top-level
    // "Records" array. Detect the payload shape instead of relying on one
    // CloudEvent type: KafkaSource may use its default type or the record
    // header depending on the content mode.
    let record_count = event
        .data
        .get("Records")
        .and_then(|value| value.as_array())
        .map(|records| records.len());
    if let Some(record_count) = record_count {
        return handle_bucket_notification(event, record_count).await;
    }
{% endif %}

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

{% if feature_cron %}
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
{% endif %}
{% if feature_s3 and feature_bucket_notifications %}
#[instrument(
    skip(event),
    fields(
        event_id = %event.id(),
        event_type = %event.r#type(),
        source = %event.source(),
        records = %records
    )
)]
async fn handle_bucket_notification(
    event: CloudEvent<serde_json::Value>,
    records: usize,
) -> Response {
    metrics::counter!("bucket_notifications_received_total").increment(1);
    info!(
        event_id = %event.id(),
        event_type = %event.r#type(),
        source = %event.source(),
        records = records,
        "Received Ceph RGW bucket notification"
    );

    Json(BucketNotificationAck {
        received: true,
        event_id: event.id().to_string(),
        records,
    })
    .into_response()
}
{% endif %}
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
