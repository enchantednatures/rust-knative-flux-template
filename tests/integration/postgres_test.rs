//! PostgreSQL demo-item handler tests
//!
//! Stateless tests (validation, `DemoItem` construction/serialization) run
//! without infrastructure and assert that the rendered handler types compile.
//! Router tests follow the `tests/health_test.rs` TestServer pattern and need
//! Redis. Tests marked `#[ignore]` additionally require a live database via
//! `DATABASE_URL`; run them with `--ignored --test-threads=1`.

#[path = "../common/mod.rs"]
mod common;

use std::sync::Arc;

use axum_test::TestServer;
use serde_json::json;
use validator::Validate;

use {{ crate_name }}::handlers::items::{DemoItem, UpsertItemRequest};
use {{ crate_name }}::routes;

#[test]
fn test_validation_rejects_empty_key() {
    let payload = UpsertItemRequest {
        key: String::new(),
        value: "value".to_string(),
    };

    assert!(payload.validate().is_err());
}

#[test]
fn test_validation_accepts_valid_payload() {
    let payload = UpsertItemRequest {
        key: "alpha".to_string(),
        value: "beta".to_string(),
    };

    assert!(payload.validate().is_ok());
}

#[test]
fn test_validation_rejects_oversized_value() {
    let payload = UpsertItemRequest {
        key: "alpha".to_string(),
        value: "x".repeat(4097),
    };

    assert!(payload.validate().is_err());
}

#[test]
fn test_demo_item_construction_and_serialization() {
    // Instantiate the FromRow-mapped type without a database to prove the
    // rendered handler types compile and serialize as documented.
    let item = DemoItem {
        id: 1,
        key: "alpha".to_string(),
        value: "beta".to_string(),
        updated_at: sqlx::types::chrono::DateTime::from_timestamp(1_700_000_000, 0)
            .expect("valid unix timestamp"),
    };

    let json = serde_json::to_value(&item).expect("should serialize");
    assert_eq!(json["id"], 1);
    assert_eq!(json["key"], "alpha");
    assert_eq!(json["value"], "beta");
    assert!(
        json["updated_at"]
            .as_str()
            .expect("updated_at is a string")
            .contains('T'),
        "updated_at should serialize as an RFC 3339 timestamp"
    );
}

#[tokio::test]
#[ignore = "requires live infra (Redis via create_test_state); run with --ignored"]
async fn test_items_routes_return_500_without_pool() {
    // create_test_state wires postgres as None: handlers must surface the
    // missing pool as a configuration error, not a panic.
    let state = common::create_test_state().await;
    let app = routes::create_router(state);
    let server = TestServer::new(app).expect("Failed to create test server");

    let response = server
        .post("/api/v1/items")
        .json(&json!({"key": "alpha", "value": "beta"}))
        .await;
    assert_eq!(response.status_code(), 500);

    let response = server.get("/api/v1/items/alpha").await;
    assert_eq!(response.status_code(), 500);
}

#[tokio::test]
#[ignore = "requires live infra (Redis via create_test_state); run with --ignored"]
async fn test_upsert_item_rejects_empty_key() {
    let state = common::create_test_state().await;
    let app = routes::create_router(state);
    let server = TestServer::new(app).expect("Failed to create test server");

    let response = server
        .post("/api/v1/items")
        .json(&json!({"key": "", "value": "beta"}))
        .await;

    assert_eq!(response.status_code(), 400);
}

#[tokio::test]
#[ignore = "requires live infra (Redis via create_test_state); run with --ignored"]
async fn test_openapi_documents_items_routes() {
    // Asserts the handler templates rendered into the OpenAPI registration.
    let state = common::create_test_state().await;
    let app = routes::create_router(state);
    let server = TestServer::new(app).expect("Failed to create test server");

    let response = server.get("/api-docs/openapi.json").await;
    assert_eq!(response.status_code(), 200);

    let body = response.text();
    assert!(
        body.contains("/api/v1/items"),
        "missing items path: {}",
        body
    );
    assert!(
        body.contains("/api/v1/items/{key}"),
        "missing item lookup path: {}",
        body
    );
}

#[tokio::test]
#[ignore = "requires live PostgreSQL via DATABASE_URL"]
async fn test_upsert_and_get_roundtrip() {
    let url = std::env::var("DATABASE_URL").expect("DATABASE_URL must be set");
    let pool = sqlx::PgPool::connect(&url)
        .await
        .expect("Failed to connect to PostgreSQL");
    sqlx::migrate!()
        .run(&pool)
        .await
        .expect("Failed to run migrations");

    let mut state = common::create_test_state().await;
    state.postgres = Some(Arc::new(pool.clone()));
    let app = routes::create_router(state);
    let server = TestServer::new(app).expect("Failed to create test server");

    let key = format!("itest-{}", uuid::Uuid::new_v4());

    let response = server
        .post("/api/v1/items")
        .json(&json!({"key": key, "value": "one"}))
        .await;
    assert_eq!(response.status_code(), 200);
    let body: serde_json::Value = response.json();
    assert_eq!(body["key"], key);
    assert_eq!(body["value"], "one");
    let id = body["id"].as_i64().expect("id should be an integer");

    // Upserting the same key keeps the id and overwrites the value.
    let response = server
        .post("/api/v1/items")
        .json(&json!({"key": key, "value": "two"}))
        .await;
    assert_eq!(response.status_code(), 200);
    let body: serde_json::Value = response.json();
    assert_eq!(body["id"].as_i64(), Some(id));
    assert_eq!(body["value"], "two");

    let response = server.get(&format!("/api/v1/items/{}", key)).await;
    assert_eq!(response.status_code(), 200);
    let body: serde_json::Value = response.json();
    assert_eq!(body["key"], key);
    assert_eq!(body["value"], "two");
    assert!(body["updated_at"].is_string());

    sqlx::query("DELETE FROM demo_items WHERE key = $1")
        .bind(&key)
        .execute(&pool)
        .await
        .expect("Failed to clean up test row");
}

#[tokio::test]
#[ignore = "requires live PostgreSQL via DATABASE_URL"]
async fn test_get_missing_item_returns_404() {
    let url = std::env::var("DATABASE_URL").expect("DATABASE_URL must be set");
    let pool = sqlx::PgPool::connect(&url)
        .await
        .expect("Failed to connect to PostgreSQL");

    let mut state = common::create_test_state().await;
    state.postgres = Some(Arc::new(pool));
    let app = routes::create_router(state);
    let server = TestServer::new(app).expect("Failed to create test server");

    let key = format!("missing-{}", uuid::Uuid::new_v4());
    let response = server.get(&format!("/api/v1/items/{}", key)).await;
    assert_eq!(response.status_code(), 404);
}

#[tokio::test]
#[ignore = "requires live PostgreSQL via DATABASE_URL"]
async fn test_readiness_reports_ready_with_live_pool() {
    let url = std::env::var("DATABASE_URL").expect("DATABASE_URL must be set");
    let pool = sqlx::PgPool::connect(&url)
        .await
        .expect("Failed to connect to PostgreSQL");

    let mut state = common::create_test_state().await;
    state.postgres = Some(Arc::new(pool));
    let app = routes::create_router(state);
    let server = TestServer::new(app).expect("Failed to create test server");

    let response = server.get("/health/ready").await;
    assert_eq!(response.status_code(), 200);
    let body: serde_json::Value = response.json();
    assert_eq!(body["status"], "ready");
}
