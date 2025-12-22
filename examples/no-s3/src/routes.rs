use axum::{routing::{get, post}, Router};
use tower_http::trace::TraceLayer;
use utoipa::OpenApi;
use utoipa_swagger_ui::SwaggerUi;

use crate::handlers::{api, health};
use crate::state::AppState;

#[derive(OpenApi)]
#[openapi(
    paths(
        health::liveness,
        health::readiness,
        api::hello,
        
    ),
    components(
        schemas(
            health::HealthResponse,
            api::HelloResponse,
            api::HelloQuery,
            
        )
    ),
    tags(
        (name = "Health", description = "Health check endpoints"),
        (name = "API", description = "Application endpoints"),
        
    ),
    info(
        title = "Rust Knative Service",
        version = env!("CARGO_PKG_VERSION"),
        description = "Template microservice for Knative + FluxCD"
    )
)]
struct ApiDoc;

pub fn create_router(state: AppState) -> Router {
    Router::new()
        // Health endpoints (not versioned)
        .route("/health/live", get(health::liveness))
        .route("/health/ready", get(health::readiness))
        // Versioned API
        .nest("/api/v1", api_v1_routes())
        // OpenAPI documentation
        .merge(SwaggerUi::new("/swagger-ui").url("/api-docs/openapi.json", ApiDoc::openapi()))
        // Add tracing middleware
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

fn api_v1_routes() -> Router<AppState> {
    Router::new()
        .route("/hello", get(api::hello))
        
}
