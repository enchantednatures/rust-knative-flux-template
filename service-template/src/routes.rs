use std::sync::Arc;

use axum::{Router, body::Body, http::Request, middleware::Next, routing};
use metrics::counter;
use tower::ServiceBuilder;
use tower_governor::GovernorLayer;
use tower_governor::governor::GovernorConfigBuilder;
use tower_http::trace::TraceLayer;
use utoipa::OpenApi;
use utoipa_swagger_ui::SwaggerUi;

use crate::handlers::api;
{%- if kafka_source %}
use crate::handlers::events;
{%- endif %}
use service_core::health;
use service_core::middleware::{request_id_middleware, security_headers_middleware};
use service_core::state::AppState;

#[derive(OpenApi)]
#[openapi(
    paths(
        health::liveness,
        health::readiness,
        health::metrics,
        api::hello,
    ),
    components(
        schemas(
            health::HealthResponse,
            api::HelloResponse,
            api::HelloQuery,
            service_core::error::ValidationErrorResponse,
        )
    ),
    tags(
        (name = "Health", description = "Health check endpoints"),
        (name = "API", description = "Application endpoints"),
    ),
    info(
        title = "{{ service_slug }} API",
        version = env!("CARGO_PKG_VERSION"),
        description = "Thin service built on the shared service-core crate"
    )
)]
struct ApiDoc;

async fn metrics_middleware(req: Request<Body>, next: Next) -> axum::response::Response {
    counter!("http_requests_total").increment(1);
    next.run(req).await
}

/// Build the HTTP router for this service.
pub fn create_router(state: AppState) -> Router {
    let governor_conf = Arc::new(
        GovernorConfigBuilder::default()
            .per_second(100)
            .burst_size(50)
            .finish()
            .expect("Failed to build rate limiter configuration"),
    );

    let api_routes = api_v1_routes().layer(GovernorLayer {
        config: governor_conf,
    });

    Router::new()
        {%- if kafka_source %}
        // CloudEvents sink consumed by the Knative KafkaSource.
        .route("/", routing::post(events::handle_event))
        {%- endif %}
        // Health endpoints (not versioned)
        .route("/health/live", routing::get(health::liveness))
        .route("/health/ready", routing::get(health::readiness))
        // Prometheus scraping endpoint
        .route("/metrics", routing::get(health::metrics))
        // Versioned API
        .nest("/api/v1", api_routes)
        .merge(SwaggerUi::new("/swagger-ui").url("/api-docs/openapi.json", ApiDoc::openapi()))
        .layer(axum::middleware::from_fn(request_id_middleware))
        .layer(axum::middleware::from_fn(security_headers_middleware))
        .layer(ServiceBuilder::new().layer(axum::middleware::from_fn(metrics_middleware)))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

fn api_v1_routes() -> Router<AppState> {
    Router::new().route("/hello", routing::get(api::hello))
}
