mod common;

use axum_test::TestServer;
use rust_knative_flux_template::routes;

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
