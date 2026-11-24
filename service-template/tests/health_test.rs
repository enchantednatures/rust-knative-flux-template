use axum::{
    Router,
    body::Body,
    http::{Request, StatusCode},
    routing::get,
};
use serde_json::Value;
use tower::ServiceExt;

use {{ crate_name }}::health::liveness;

#[tokio::test]
async fn liveness_route_returns_alive() {
    let app = Router::new().route("/health/live", get(liveness));

    let response = app
        .oneshot(
            Request::builder()
                .uri("/health/live")
                .body(Body::empty())
                .expect("valid request"),
        )
        .await
        .expect("router responds");

    assert_eq!(response.status(), StatusCode::OK);

    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("body bytes");
    let json: Value = serde_json::from_slice(&body).expect("json body");

    assert_eq!(json["status"], "alive");
}
