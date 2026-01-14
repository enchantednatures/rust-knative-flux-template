mod common;

use axum::http::StatusCode;
use axum_test::TestServer;
use serde_json::json;

use audio_exporter::routes;

#[tokio::test]
async fn test_cloudevent_ping() {
    let state = common::create_test_state().await;
    let app = routes::create_router(state);
    let server = TestServer::new(app).expect("Failed to create test server");

    let response = server
        .post("/")
        .content_type("application/json")
        .json(&json!({
            "specversion": "1.0",
            "id": "test-123",
            "type": "ping",
            "source": "/test",
            "data": {
                "message": "hello"
            }
        }))
        .await;

    response.assert_status_ok();
    response.assert_json(&json!({
        "reply": "pong: hello",
        "event_id": "test-123"
    }));
}

#[tokio::test]
async fn test_cloudevent_missing_id() {
    let state = common::create_test_state().await;
    let app = routes::create_router(state);
    let server = TestServer::new(app).expect("Failed to create test server");

    let response = server
        .post("/")
        .content_type("application/json")
        .json(&json!({
            "specversion": "1.0",
            "type": "ping",
            "source": "/test",
            "data": {
                "message": "hello"
            }
        }))
        .await;

    response.assert_status(StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn test_cloudevent_invalid_json() {
    let state = common::create_test_state().await;
    let app = routes::create_router(state);
    let server = TestServer::new(app).expect("Failed to create test server");

    let response = server
        .post("/")
        .content_type("application/json")
        .text("{ invalid json }")
        .await;

    response.assert_status(StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn test_cloudevent_with_custom_message() {
    let state = common::create_test_state().await;
    let app = routes::create_router(state);
    let server = TestServer::new(app).expect("Failed to create test server");

    let response = server
        .post("/")
        .content_type("application/json")
        .json(&json!({
            "specversion": "1.0",
            "id": "test-456",
            "type": "ping",
            "source": "/test",
            "data": {
                "message": "testing 123"
            }
        }))
        .await;

    response.assert_status_ok();
    response.assert_json(&json!({
        "reply": "pong: testing 123",
        "event_id": "test-456"
    }));
}
