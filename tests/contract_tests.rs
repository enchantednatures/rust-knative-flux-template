//! Contract tests using Pact
//!
//! These tests verify API contracts between the service and its consumers.
//! Run with: `cargo test --test contract_tests`

use pact_consumer::mock_server::StartMockServer;
use pact_consumer::prelude::*;

#[tokio::test]
async fn test_hello_endpoint_contract() {
    let mock_server = PactBuilder::new("consumer-service", "{{ crate_name }}")
        .interaction("a request for hello", "", |mut i| {
            i.request.path("/api/v1/hello").method("GET");

            i.response
                .status(200)
                .header("Content-Type", "application/json")
                .json_body(json_pattern!({
                    "message": like!("Hello, World!"),
                    "version": like!("0.1.0"),
                    "request_id": like!(null)
                }));

            i
        })
        .start_mock_server(None, None);

    let url = mock_server.url();

    let client = reqwest::Client::new();
    let response = client
        .get(format!("{url}api/v1/hello"))
        .send()
        .await
        .expect("Failed to make request");

    assert_eq!(response.status(), 200);

    let body: serde_json::Value = response.json().await.expect("Failed to parse JSON");
    assert!(body.get("message").is_some());
    assert!(body.get("version").is_some());
}

#[tokio::test]
async fn test_hello_with_name_contract() {
    let mock_server = PactBuilder::new("consumer-service", "{{ crate_name }}")
        .interaction("a request for hello with name", "", |mut i| {
            i.request
                .path("/api/v1/hello")
                .method("GET")
                .query_param("name", "Alice");

            i.response
                .status(200)
                .header("Content-Type", "application/json")
                .json_body(json_pattern!({
                    "message": like!("Hello, Alice!"),
                    "version": like!("0.1.0"),
                    "request_id": like!(null)
                }));

            i
        })
        .start_mock_server(None, None);

    let url = mock_server.url();

    let client = reqwest::Client::new();
    let response = client
        .get(format!("{url}api/v1/hello?name=Alice"))
        .send()
        .await
        .expect("Failed to make request");

    assert_eq!(response.status(), 200);
}

#[tokio::test]
async fn test_health_endpoints_contract() {
    let mock_server = PactBuilder::new("monitoring-service", "{{ crate_name }}")
        .interaction("liveness probe request", "", |mut i| {
            i.request.path("/health/live").method("GET");

            i.response
                .status(200)
                .header("Content-Type", "application/json")
                .json_body(json_pattern!({
                    "status": "alive"
                }));

            i
        })
        .interaction("readiness probe request", "", |mut i| {
            i.request.path("/health/ready").method("GET");

            i.response
                .status(200)
                .header("Content-Type", "application/json")
                .json_body(json_pattern!({
                    "status": "ready"
                }));

            i
        })
        .start_mock_server(None, None);

    let url = mock_server.url();

    let client = reqwest::Client::new();
    let liveness = client
        .get(format!("{url}health/live"))
        .send()
        .await
        .expect("Failed to make liveness request");
    assert_eq!(liveness.status(), 200);

    let readiness = client
        .get(format!("{url}health/ready"))
        .send()
        .await
        .expect("Failed to make readiness request");
    assert_eq!(readiness.status(), 200);
}

#[tokio::test]
async fn test_metrics_endpoint_contract() {
    let mock_server = PactBuilder::new("prometheus", "{{ crate_name }}")
        .interaction("metrics scrape request", "", |mut i| {
            i.request.path("/metrics").method("GET");

            i.response
                .status(200)
                .header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
                .body_matching(term!(r"http_requests_total.*", "http_requests_total 1"));

            i
        })
        .start_mock_server(None, None);

    let url = mock_server.url();

    let client = reqwest::Client::new();
    let response = client
        .get(format!("{url}metrics"))
        .send()
        .await
        .expect("Failed to make metrics request");

    assert_eq!(response.status(), 200);

    let body = response.text().await.expect("Failed to get text");
    assert!(body.contains("http_requests_total"));
}

#[tokio::test]
async fn test_validation_error_contract() {
    let mock_server = PactBuilder::new("consumer-service", "{{ crate_name }}")
        .interaction("invalid name parameter", "", |mut i| {
            i.request
                .path("/api/v1/hello")
                .method("GET")
                .query_param("name", "<script>");

            i.response
                .status(400)
                .header("Content-Type", "application/json")
                .json_body(json_pattern!({
                    "error": "Invalid input",
                    "details": like!([]),
                    "request_id": like!(null)
                }));

            i
        })
        .start_mock_server(None, None);

    let url = mock_server.url();

    let client = reqwest::Client::new();
    let response = client
        .get(format!("{url}api/v1/hello?name=%3Cscript%3E"))
        .send()
        .await
        .expect("Failed to make request");

    assert_eq!(response.status(), 400);
}

{%- if feature_s3 %}
#[tokio::test]
async fn test_storage_endpoint_contract() {
    let mock_server = PactBuilder::new("storage-consumer", "{{ crate_name }}")
        .interaction("storage example request", "", |mut i| {
            i.request.path("/api/v1/storage/example").method("POST");

            i.response
                .status(200)
                .header("Content-Type", "application/json")
                .json_body(json_pattern!({
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
        .start_mock_server(None, None);

    let url = mock_server.url();

    let client = reqwest::Client::new();
    let response = client
        .post(format!("{url}api/v1/storage/example"))
        .send()
        .await
        .expect("Failed to make request");

    assert_eq!(response.status(), 200);
}
{%- endif %}

#[tokio::test]
async fn test_rate_limit_contract() {
    let mock_server = PactBuilder::new("load-tester", "{{ crate_name }}")
        .interaction("rate limit exceeded", "", |mut i| {
            i.request.path("/api/v1/hello").method("GET");

            i.response
                .status(429)
                .header("Content-Type", "application/json")
                .header("X-RateLimit-Limit", "100")
                .json_body(json_pattern!({
                    "error": "Rate limit exceeded",
                    "details": like!([]),
                    "request_id": like!(null)
                }));

            i
        })
        .start_mock_server(None, None);

    let url = mock_server.url();

    let client = reqwest::Client::new();
    let response = client
        .get(format!("{url}api/v1/hello"))
        .send()
        .await
        .expect("Failed to make request");

    assert_eq!(response.status(), 429);
}
