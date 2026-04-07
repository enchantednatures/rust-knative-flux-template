use std::sync::Arc;

use axum::{
    Router,
    body::Body,
    http::Request,
    middleware::Next,
    routing::{get, post},
};
use metrics::counter;
use tower::ServiceBuilder;
use tower_governor::GovernorLayer;
use tower_governor::governor::GovernorConfigBuilder;
use tower_http::trace::TraceLayer;
use utoipa::OpenApi;
use utoipa_swagger_ui::SwaggerUi;

use crate::handlers::{api, events, health};
use crate::middleware::{request_id_middleware, security_headers_middleware};
use crate::state::AppState;

#[derive(OpenApi)]
#[openapi(
    paths(
        health::liveness,
        health::readiness,
        health::metrics,
        api::hello,
        {%- if feature_s3 %}
        crate::handlers::storage::storage_example,
        {%- endif %}
    ),
    components(
        schemas(
            health::HealthResponse,
            api::HelloResponse,
            api::HelloQuery,
            crate::error::ValidationErrorResponse,
            {%- if feature_s3 %}
            crate::handlers::storage::StorageTestData,
            crate::handlers::storage::StorageExampleResponse,
            {%- endif %}
        )
    ),
    tags(
        (name = "Health", description = "Health check endpoints"),
        (name = "API", description = "Application endpoints"),
        {%- if feature_s3 %}
        (name = "Storage", description = "S3 storage examples"),
        {%- endif %}
    ),
    info(
        title = "Rust Knative Service",
        version = env!("CARGO_PKG_VERSION"),
        description = "Template microservice for Knative + FluxCD with rate limiting, validation, and security headers"
    )
)]
struct ApiDoc;

async fn metrics_middleware(req: Request<Body>, next: Next) -> axum::response::Response {
    let counter = counter!("http_requests_total");
    counter.increment(1);
    tracing::debug!("HTTP request counted");
    next.run(req).await
}

pub fn create_router(state: AppState) -> Router {
    let governor_conf = Arc::new(
        GovernorConfigBuilder::default()
            .per_second(100)
            .burst_size(50)
            .finish()
            .expect("Failed to build rate limiter configuration"),
    );

    Router::new()
        // CloudEvents endpoint (Knative sink)
        .route("/", post(events::handle_event))
        // Health endpoints (not versioned)
        .route("/health/live", get(health::liveness))
        .route("/health/ready", get(health::readiness))
        // Metrics endpoint (Prometheus scraping)
        .route("/metrics", get(health::metrics))
        // Versioned API
        .nest("/api/v1", api_v1_routes())
        // OpenAPI documentation
        .merge(SwaggerUi::new("/swagger-ui").url("/api-docs/openapi.json", ApiDoc::openapi()))
        // Add request ID propagation middleware (first to capture request ID)
        .layer(axum::middleware::from_fn(request_id_middleware))
        // Add security headers middleware
        .layer(axum::middleware::from_fn(security_headers_middleware))
        // Add rate limiting middleware
        .layer(GovernorLayer {
            config: governor_conf,
        })
        // Add simple metrics middleware (records HTTP request counts)
        .layer(ServiceBuilder::new().layer(axum::middleware::from_fn(metrics_middleware)))
        // Add tracing middleware
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

fn api_v1_routes() -> Router<AppState> {
    {%- if feature_s3 %}
    Router::new().route("/hello", get(api::hello)).route(
        "/storage/example",
        post(crate::handlers::storage::storage_example),
    )
    {%- else %}
    Router::new().route("/hello", get(api::hello))
    {%- endif %}
}
