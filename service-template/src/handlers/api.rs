use axum::{Json, extract::Query};
use serde::{Deserialize, Serialize};
use tracing::instrument;
use utoipa::ToSchema;

use crate::error::AppError;

#[derive(Debug, Deserialize, ToSchema)]
pub struct HelloQuery {
    /// Name to greet (defaults to `World`).
    #[schema(example = "World")]
    pub name: Option<String>,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct HelloResponse {
    pub message: String,
    pub version: String,
}

/// Demo endpoint: `GET /api/v1/hello`.
#[utoipa::path(
    get,
    path = "/api/v1/hello",
    tag = "API",
    params(
        ("name" = Option<String>, Query, description = "Name to greet")
    ),
    responses(
        (status = 200, description = "Success", body = HelloResponse),
        (status = 400, description = "Invalid input", body = crate::error::ValidationErrorResponse)
    )
)]
#[instrument(level = "debug", skip(query), fields(handler = "hello", name = ?query.name))]
pub async fn hello(Query(query): Query<HelloQuery>) -> Result<Json<HelloResponse>, AppError> {
    let name = query
        .name
        .as_deref()
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .unwrap_or("World");

    tracing::info!(name = %name, "Processing hello request");

    Ok(Json(HelloResponse {
        message: format!("Hello, {}!", name),
        version: env!("CARGO_PKG_VERSION").into(),
    }))
}
