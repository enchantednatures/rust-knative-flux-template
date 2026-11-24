use axum::{Json, extract::Query};
{%- if kafka_source %}
use axum_cloudevents::{CloudEvent, CloudEventMetadata};
{%- endif %}

use {{ crate_name }}::handlers::api::{HelloQuery, hello};
{%- if kafka_source %}
use {{ crate_name }}::handlers::events::{Ping, handle_event};
{%- endif %}

#[tokio::test]
async fn hello_returns_greeting() {
    let Json(response) = hello(Query(HelloQuery {
        name: Some("Rust".into()),
    }))
    .await
    .expect("hello succeeds");

    assert_eq!(response.message, "Hello, Rust!");
    assert_eq!(response.version, env!("CARGO_PKG_VERSION"));
}

#[tokio::test]
async fn hello_defaults_to_world() {
    let Json(response) = hello(Query(HelloQuery { name: None }))
        .await
        .expect("hello succeeds");

    assert_eq!(response.message, "Hello, World!");
}

{%- if kafka_source %}
#[tokio::test]
async fn cloudevent_ping_is_echoed() {
    let event = CloudEvent::new(
        CloudEventMetadata::new("test-123", "/test", "ping"),
        Ping {
            message: "hello".into(),
        },
    );

    let Json(response) = handle_event(event).await;

    assert_eq!(response.reply, "pong: hello");
    assert_eq!(response.event_id, "test-123");
}
{%- endif %}
