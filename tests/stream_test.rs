mod common;

use std::net::SocketAddr;
use std::time::Duration;

use reqwest::Client;
use tokio::net::TcpListener;

#[tokio::test]
async fn stream_returns_sse_heartbeat() {
    let state = common::create_test_state().await;
    let app = {{ crate_name }}::routes::create_router(state);

    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("failed to bind test listener");
    let addr = listener.local_addr().expect("failed to read listener address");

    tokio::spawn(async move {
        axum::serve(
            listener,
            app.into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await
        .expect("test server failed");
    });

    let response = Client::new()
        .get(format!("http://{addr}/api/v1/stream"))
        .send()
        .await
        .expect("SSE request failed");

    assert_eq!(response.status(), 200);
    let content_type = response.headers()["content-type"]
        .to_str()
        .unwrap_or("<invalid>");
    assert!(
        content_type.starts_with("text/event-stream"),
        "unexpected content-type: {content_type}"
    );

    let mut response = response;
    let chunk = tokio::time::timeout(Duration::from_secs(5), response.chunk())
        .await
        .expect("timed out waiting for the first SSE event")
        .expect("failed to read the first SSE chunk")
        .expect("stream ended before the first event");
    let text = String::from_utf8_lossy(&chunk);

    assert!(text.contains("event: heartbeat"), "unexpected SSE chunk: {text}");
    assert!(text.contains("\"seq\":1"), "unexpected SSE chunk: {text}");
}
