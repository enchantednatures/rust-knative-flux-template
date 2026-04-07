use std::net::SocketAddr;
use std::num::NonZeroU32;
use std::sync::Arc;

use axum::{
    Router,
    body::Body,
    http::Request,
    middleware::Next,
    routing::{get, post},
};
use governor::{
    Quota, RateLimiter, clock::DefaultClock, middleware::NoOpMiddleware, state::InMemoryState,
};
use metrics::counter;
use tower::ServiceBuilder;
use tower_governor::{GovernorConfigBuilder, GovernorLayer, errors::display_error};
use tower_http::trace::TraceLayer;
use utoipa::OpenApi;
use utoipa_swagger_ui::SwaggerUi;

use crate::handlers::{api, events, health};
use crate::middleware::{common_middleware, request_id_middleware, security_headers_middleware};
use crate::state::AppState;

/// Rate limiter configuration
///
/// Default: 100 requests per second per IP with burst of 50
pub fn rate_limit_config() -> GovernorConfigBuilder<InMemoryState, DefaultClock, NoOpMiddleware> {
    GovernorConfigBuilder::default()
        .per_second(100)
        .burst_size(50)
        .use_headers()
}

/// Key extractor for rate limiting by IP address
#[derive(Clone)]
pub struct RateLimitKeyExtractor;

impl tower_governor::key_extractor::KeyExtractor for RateLimitKeyExtractor {
    type Key = SocketAddr;

    fn extract<B>(&self, req: &Request<B>) -> Result<Self::Key, axum::response::Response> {
        req.extensions()
            .get::<SocketAddr>()
            .cloned()
            .ok_or_else(|| {
                axum::response::Response::builder()
                    .status(axum::http::StatusCode::INTERNAL_SERVER_ERROR)
                    .body(axum::body::Body::from("Could not extract client IP"))
                    .unwrap()
            })
    }
}

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

/// Simple metrics middleware that records HTTP request counts
async fn metrics_middleware(req: Request<Body>, next: Next) -> axum::response::Response {
    let counter = counter!("http_requests_total");
    counter.increment(1);
    tracing::debug!("HTTP request counted");
    next.run(req).await
}

pub fn create_router(state: AppState) -> Router {
    // Configure rate limiting
    let governor_conf = Arc::new(
        rate_limit_config()
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
