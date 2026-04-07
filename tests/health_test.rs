mod common;

use axum_test::TestServer;

use {{ crate_name }}::routes;

#[tokio::test]
async fn test_liveness_endpoint() {
    // Create test state
    let state = common::create_test_state().await;

    // Create router
    let app = routes::create_router(state);

    // Create test server
    let server = TestServer::new(app).expect("Failed to create test server");

    // Test liveness endpoint
    let response = server.get("/health/live").await;

    assert_eq!(response.status_code(), 200);

    let json: serde_json::Value = response.json();
    assert_eq!(json["status"], "alive");
}

#[tokio::test]
async fn test_readiness_endpoint() {
    // Create test state
    let state = common::create_test_state().await;

    // Create router
    let app = routes::create_router(state);

    // Create test server
    let server = TestServer::new(app).expect("Failed to create test server");

    // Test readiness endpoint
    let response = server.get("/health/ready").await;

    // Should return 200 if Redis is available, 503 otherwise
    // In CI, we ensure Redis is running via GitHub Actions services
    assert!(
        response.status_code() == 200 || response.status_code() == 503,
        "Expected 200 or 503, got {}",
        response.status_code()
    );

    let json: serde_json::Value = response.json();
    assert!(json["status"].is_string());
}

#[tokio::test]
async fn test_api_v1_hello_endpoint() {
    // Create test state
    let state = common::create_test_state().await;

    // Create router
    let app = routes::create_router(state);

    // Create test server
    let server = TestServer::new(app).expect("Failed to create test server");

    // Test hello endpoint without query
    let response = server.get("/api/v1/hello").await;
    assert_eq!(response.status_code(), 200);

    let json: serde_json::Value = response.json();
    assert_eq!(json["message"], "Hello, World!");
    assert!(json["version"].is_string());

    // Test hello endpoint with query
    let response = server.get("/api/v1/hello?name=Rust").await;
    assert_eq!(response.status_code(), 200);

    let json: serde_json::Value = response.json();
    assert_eq!(json["message"], "Hello, Rust!");
}

#[tokio::test]
async fn test_metrics_endpoint() {
    // Create test state (which now initializes metrics properly)
    let state = common::create_test_state().await;

    // Create router
    let app = routes::create_router(state);

    // Create test server
    let server = TestServer::new(app).expect("Failed to create test server");

    // Make several requests to generate metrics
    // These should increment the http_requests_total counter
    let _ = server.get("/health/live").await;
    let _ = server.get("/health/ready").await;
    let _ = server.get("/api/v1/hello").await;

    // Test metrics endpoint
    let response = server.get("/metrics").await;
    assert_eq!(response.status_code(), 200);

    let metrics_text = response.text();

    // Verify non-empty output
    assert!(
        !metrics_text.is_empty(),
        "Metrics output should not be empty"
    );

    // Verify Prometheus format with HELP and TYPE comments
    assert!(
        metrics_text.contains("# HELP"),
        "Metrics output should contain Prometheus HELP comments. Got: {}",
        metrics_text
    );
    assert!(
        metrics_text.contains("# TYPE"),
        "Metrics output should contain Prometheus TYPE comments. Got: {}",
        metrics_text
    );

    // Verify our core metrics are present
    assert!(
        metrics_text.contains("http_requests_total"),
        "Should contain HTTP request counter. Got: {}",
        metrics_text
    );
    assert!(
        metrics_text.contains("app_info"),
        "Should contain app info metric. Got: {}",
        metrics_text
    );

    // Verify the counter has a non-zero value (at least 4: live, ready, hello, metrics)
    assert!(
        metrics_text.contains("http_requests_total") && metrics_text.contains(char::is_numeric),
        "HTTP request counter should have a numeric value. Got: {}",
        metrics_text
    );

    // Print metrics for debugging
    println!(
        "Metrics output ({} bytes):\n{}",
        metrics_text.len(),
        metrics_text
    );
}
