//! Contract tests using Pact
//!
//! These tests verify API contracts between the service and its consumers.
//! Run with: `cargo test --test contract_tests`

use pact_consumer::mock_server::StartMockServerAsync;
use pact_consumer::prelude::*;
use pact_models::v4::http_parts::HttpRequest;
use reqwest;
use serde_json::json;

/// Contract test for the hello endpoint
///
/// Verifies that:
/// - GET /api/v1/hello returns 200 with correct response structure
/// - Response contains expected fields (message, version)
#[tokio::test]
async fn test_hello_endpoint_contract() {
    let pact = PactBuilder::new("consumer-service", "{{ crate_name }}")
        .interaction("a request for hello", "", |mut i| async move {
            i.request.path("/api/v1/hello").method("GET");

            i.response
                .status(200)
                .header("Content-Type", "application/json")
                .json_body(json!({
                    "message": like!("Hello, World!"),
                    "version": like!("0.1.0"),
                    "request_id": like!(null)
                }));

            i
        })
        .await;

    let mock_server = pact.start_mock_server_async().await;
    let url = mock_server.url();

    // Make the request
    let response = reqwest::get(format!("{}/api/v1/hello", url))
        .await
        .expect("Failed to make request");

    assert_eq!(response.status(), 200);

    let body: serde_json::Value = response.json().await.expect("Failed to parse JSON");
    assert!(body.get("message").is_some());
    assert!(body.get("version").is_some());
}

/// Contract test for the hello endpoint with name parameter
#[tokio::test]
async fn test_hello_with_name_contract() {
    let pact = PactBuilder::new("consumer-service", "{{ crate_name }}")
        .interaction("a request for hello with name", "", |mut i| async move {
            i.request
                .path("/api/v1/hello")
                .method("GET")
                .query_param("name", "Alice");

            i.response
                .status(200)
                .header("Content-Type", "application/json")
                .json_body(json!({
                    "message": like!("Hello, Alice!"),
                    "version": like!("0.1.0"),
                    "request_id": like!(null)
                }));

            i
        })
        .await;

    let mock_server = pact.start_mock_server_async().await;
    let url = mock_server.url();

    let response = reqwest::get(format!("{}/api/v1/hello?name=Alice", url))
        .await
        .expect("Failed to make request");

    assert_eq!(response.status(), 200);
}

/// Contract test for health endpoints
#[tokio::test]
async fn test_health_endpoints_contract() {
    let pact = PactBuilder::new("monitoring-service", "{{ crate_name }}")
        .interaction("liveness probe request", "", |mut i| async move {
            i.request.path("/health/live").method("GET");

            i.response
                .status(200)
                .header("Content-Type", "application/json")
                .json_body(json!({
                    "status": "alive"
                }));

            i
        })
        .await
        .interaction("readiness probe request", "", |mut i| async move {
            i.request.path("/health/ready").method("GET");

            i.response
                .status(200)
                .header("Content-Type", "application/json")
                .json_body(json!({
                    "status": "ready"
                }));

            i
        })
        .await;

    let mock_server = pact.start_mock_server_async().await;
    let url = mock_server.url();

    // Test liveness
    let liveness = reqwest::get(format!("{}/health/live", url))
        .await
        .expect("Failed to make liveness request");
    assert_eq!(liveness.status(), 200);

    // Test readiness
    let readiness = reqwest::get(format!("{}/health/ready", url))
        .await
        .expect("Failed to make readiness request");
    assert_eq!(readiness.status(), 200);
}

/// Contract test for metrics endpoint
#[tokio::test]
async fn test_metrics_endpoint_contract() {
    let pact = PactBuilder::new("prometheus", "{{ crate_name }}")
        .interaction("metrics scrape request", "", |mut i| async move {
            i.request.path("/metrics").method("GET");

            i.response
                .status(200)
                .header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
                .body(term!(r"http_requests_total.*", "http_requests_total 1"));

            i
        })
        .await;

    let mock_server = pact.start_mock_server_async().await;
    let url = mock_server.url();

    let response = reqwest::get(format!("{}/metrics", url))
        .await
        .expect("Failed to make metrics request");

    assert_eq!(response.status(), 200);

    let body = response.text().await.expect("Failed to get text");
    assert!(body.contains("http_requests_total"));
}

/// Contract test for validation error responses
#[tokio::test]
async fn test_validation_error_contract() {
    let pact = PactBuilder::new("consumer-service", "{{ crate_name }}")
        .interaction("invalid name parameter", "", |mut i| async move {
            i.request
                .path("/api/v1/hello")
                .method("GET")
                .query_param("name", "<script>");

            i.response
                .status(400)
                .header("Content-Type", "application/json")
                .json_body(json!({
                    "error": "Invalid input",
                    "details": like!([]),
                    "request_id": like!(null)
                }));

            i
        })
        .await;

    let mock_server = pact.start_mock_server_async().await;
    let url = mock_server.url();

    let response = reqwest::get(format!("{}/api/v1/hello?name=%3Cscript%3E", url))
        .await
        .expect("Failed to make request");

    // Should return 400 for invalid input
    assert_eq!(response.status(), 400);
}

{%- if feature_s3 %}
/// Contract test for storage endpoint (when S3 feature is enabled)
#[tokio::test]
async fn test_storage_endpoint_contract() {
    let pact = PactBuilder::new("storage-consumer", "{{ crate_name }}")
        .interaction("storage example request", "", |mut i| async move {
            i.request.path("/api/v1/storage/example").method("POST");

            i.response
                .status(200)
                .header("Content-Type", "application/json")
                .json_body(json!({
                    "success": true,
                    "write_key": like!("test/"),
                    "write_size": like!(100),
                    "read_verified": true,
                    "data": {
                        "message": like!("Hello from S3 storage!"),
                        "timestamp": like!("2024-01-01T00:00:00Z"),
                        "test_id": like!("uuid")
                    }
                }));

            i
        })
        .await;

    let mock_server = pact.start_mock_server_async().await;
    let url = mock_server.url();

    let client = reqwest::Client::new();
    let response = client
        .post(format!("{}/api/v1/storage/example", url))
        .send()
        .await
        .expect("Failed to make request");

    assert_eq!(response.status(), 200);
}
{%- endif %}

/// Contract test for rate limiting
#[tokio::test]
async fn test_rate_limit_contract() {
    let pact = PactBuilder::new("load-tester", "{{ crate_name }}")
        .interaction("rate limit exceeded", "", |mut i| async move {
            i.request.path("/api/v1/hello").method("GET");

            i.response
                .status(429)
                .header("Content-Type", "application/json")
                .header("X-RateLimit-Limit", "100")
                .json_body(json!({
                    "error": "Rate limit exceeded",
                    "details": like!([]),
                    "request_id": like!(null)
                }));

            i
        })
        .await;

    let mock_server = pact.start_mock_server_async().await;
    let url = mock_server.url();

    let response = reqwest::get(format!("{}/api/v1/hello", url))
        .await
        .expect("Failed to make request");

    assert_eq!(response.status(), 429);
}
