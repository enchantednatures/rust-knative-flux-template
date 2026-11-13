use std::convert::Infallible;
use std::time::{Duration, Instant};

use async_stream::stream;
use axum::response::IntoResponse;
use axum::response::sse::{Event, KeepAlive, Sse};
use serde_json::{Value, json};
use tracing::instrument;

/// How often the SSE stream emits a heartbeat event. The first event is
/// emitted immediately; subsequent events keep the connection alive and let
/// clients detect a dead proxy.
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(15);

/// Tracks how many long-lived streams are open and how many have been opened
/// in total. The guard is moved into the stream so dropping the response (for
/// example when the client disconnects) decrements the gauge.
struct ActiveStreamGuard;

impl ActiveStreamGuard {
    fn new() -> Self {
        metrics::counter!("stream_connections_total").increment(1);
        metrics::gauge!("stream_connections_active").increment(1.0);
        Self
    }
}

impl Drop for ActiveStreamGuard {
    fn drop(&mut self) {
        metrics::gauge!("stream_connections_active").decrement(1.0);
    }
}

/// Build the JSON payload for one heartbeat.
fn heartbeat_payload(seq: u64, uptime: Duration) -> Value {
    json!({
        "seq": seq,
        "uptime_seconds": uptime.as_secs(),
        "service": env!("CARGO_PKG_NAME"),
    })
}

/// Build one SSE event. `json_data` cannot fail for a `serde_json::Value`, but
/// keep a defensive fallback so the stream never panics on serialization.
fn heartbeat_event(seq: u64, uptime: Duration) -> Event {
    Event::default()
        .event("heartbeat")
        .json_data(heartbeat_payload(seq, uptime))
        .unwrap_or_else(|_| Event::default().event("heartbeat").data("{}"))
}

/// Long-lived Server-Sent Events stream.
///
/// This is the example endpoint for `workload_type = "Deployment"`: the
/// connection stays open indefinitely (until the client disconnects or the pod
/// is terminated), which is not possible through Knative's default 300s
/// request timeout. Clients should reconnect on disconnect.
#[utoipa::path(
    get,
    path = "/api/v1/stream",
    tag = "Streaming",
    responses(
        (status = 200, description = "Server-Sent Events heartbeat stream", content_type = "text/event-stream")
    )
)]
#[instrument]
pub async fn stream() -> impl IntoResponse {
    let started = Instant::now();

    let events = stream! {
        // Keep the guard alive for the lifetime of the response stream.
        let _guard = ActiveStreamGuard::new();
        let mut interval = tokio::time::interval(HEARTBEAT_INTERVAL);
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut seq: u64 = 0;

        loop {
            interval.tick().await;
            seq += 1;
            metrics::counter!("stream_heartbeats_sent_total").increment(1);
            yield Ok::<Event, Infallible>(heartbeat_event(seq, started.elapsed()));
        }
    };

    Sse::new(events).keep_alive(KeepAlive::default())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn heartbeat_payload_contains_sequence_and_uptime() {
        let payload = heartbeat_payload(7, Duration::from_secs(42));

        assert_eq!(payload["seq"], 7);
        assert_eq!(payload["uptime_seconds"], 42);
        assert_eq!(payload["service"], env!("CARGO_PKG_NAME"));
    }
}
