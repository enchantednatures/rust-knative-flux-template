use axum::{
    Router,
    body::Body,
    http::Request,
    middleware::Next,
    routing::{get, post},
};
use metrics::counter;
use tower::ServiceBuilder;
use tower_http::trace::TraceLayer;
use utoipa::OpenApi;
use utoipa_swagger_ui::SwaggerUi;

use crate::handlers::{api, events, health};
use crate::state::AppState;

#[derive(OpenApi)]
#[openapi(
    paths(
        health::liveness,
        health::readiness,
        health::metrics,
        api::hello,
        crate::handlers::storage::storage_example,
    ),
    components(
        schemas(
            health::HealthResponse,
            api::HelloResponse,
            api::HelloQuery,
            crate::handlers::storage::StorageTestData,
            crate::handlers::storage::StorageExampleResponse,
        )
    ),
    tags(
        (name = "Health", description = "Health check endpoints"),
        (name = "API", description = "Application endpoints"),
        (name = "Storage", description = "S3 storage examples"),
    ),
    info(
        title = "Rust Knative Service",
        version = env!("CARGO_PKG_VERSION"),
        description = "Template microservice for Knative + FluxCD"
    )
)]
struct ApiDoc;

/// Simple metrics middleware that records HTTP request counts
async fn metrics_middleware(req: Request<Body>, next: Next) -> axum::response::Response {
    counter!("http_requests_total", 1);
    next.run(req).await
}

pub fn create_router(state: AppState) -> Router {
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
        // Add simple metrics middleware (records HTTP request counts)
        .layer(ServiceBuilder::new().layer(axum::middleware::from_fn(metrics_middleware)))
        // Add tracing middleware
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

fn api_v1_routes() -> Router<AppState> {
    Router::new().route("/hello", get(api::hello)).route(
        "/storage/example",
        post(crate::handlers::storage::storage_example),
    )
}
