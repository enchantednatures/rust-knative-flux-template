use axum::{extract::State, Json};
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

use crate::state::AppState;

#[derive(Serialize, ToSchema)]
pub struct HelloResponse {
    pub message: String,
    pub version: String,
}

#[derive(Deserialize, ToSchema)]
pub struct HelloQuery {
    pub name: Option<String>,
}

/// Hello endpoint - example API handler
///
/// Demonstrates:
/// - Versioned API route (/api/v1/hello)
/// - State access
/// - OpenAPI documentation
/// - Tracing (automatic via tower-http)
#[utoipa::path(
    get,
    path = "/api/v1/hello",
    tag = "API",
    params(
        ("name" = Option<String>, Query, description = "Name to greet")
    ),
    responses(
        (status = 200, description = "Success", body = HelloResponse)
    )
)]
pub async fn hello(
    State(_state): State<AppState>,
    axum::extract::Query(query): axum::extract::Query<HelloQuery>,
) -> Json<HelloResponse> {
    let name = query.name.unwrap_or_else(|| "World".into());

    tracing::info!(name = %name, "Hello endpoint called");

    Json(HelloResponse {
        message: format!("Hello, {}!", name),
        version: env!("CARGO_PKG_VERSION").into(),
    })
}
