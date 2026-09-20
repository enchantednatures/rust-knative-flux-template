//! PostgreSQL demo item CRUD handlers
//!
//! sqlx example against the `demo_items` table (migrations/0001_create_demo_items.sql):
//! an idempotent upsert by natural key and a point lookup, both returning the full row.

{%- if feature_postgres %}
use axum::{
    Json,
    extract::{Path, State},
};
use serde::{Deserialize, Serialize};
use sqlx::types::chrono::{DateTime, Utc};
use tracing::instrument;
use utoipa::ToSchema;
use validator::Validate;

use crate::{error::AppError, state::AppState};

/// Row shape of the `demo_items` table
#[derive(Debug, Serialize, sqlx::FromRow, ToSchema)]
pub struct DemoItem {
    pub id: i64,
    pub key: String,
    pub value: String,
    // `serialize_with` keeps this type serializable without requiring the
    // `chrono/serde` feature, which the template does not enable directly.
    #[serde(serialize_with = "serialize_updated_at")]
    #[schema(value_type = String)]
    pub updated_at: DateTime<Utc>,
}

fn serialize_updated_at<S>(value: &DateTime<Utc>, serializer: S) -> Result<S::Ok, S::Error>
where
    S: serde::Serializer,
{
    serializer.serialize_str(&value.to_rfc3339())
}

#[derive(Debug, Deserialize, ToSchema, Validate)]
pub struct UpsertItemRequest {
    #[validate(length(
        min = 1,
        max = 255,
        message = "Key must be between 1 and 255 characters"
    ))]
    pub key: String,
    #[validate(length(max = 4096, message = "Value must be at most 4096 characters"))]
    pub value: String,
}

/// Maps a sqlx failure to `AppError::Database` with structured log context
fn database_error(operation: &str, err: sqlx::Error) -> AppError {
    let error_kind = match &err {
        sqlx::Error::Database(_) => "database",
        sqlx::Error::Io(_) => "io",
        sqlx::Error::Tls(_) => "tls",
        sqlx::Error::PoolTimedOut => "pool_timed_out",
        sqlx::Error::PoolClosed => "pool_closed",
        sqlx::Error::WorkerCrashed => "worker_crashed",
        _ => "other",
    };
    tracing::error!(
        error = %err,
        error_kind = %error_kind,
        operation = %operation,
        "PostgreSQL operation failed"
    );
    AppError::Database(format!("{}: {}", operation, err))
}

fn require_pool(state: &AppState) -> Result<&sqlx::PgPool, AppError> {
    state
        .postgres
        .as_deref()
        .ok_or_else(|| AppError::Config("postgres not configured".to_string()))
}

/// Create or update a demo item (upsert by natural key)
///
/// `ON CONFLICT (key) DO UPDATE` makes retries idempotent: a repeated
/// submission for the same key overwrites the value, refreshes `updated_at`,
/// and returns the stored row in a single round trip.
#[utoipa::path(
    post,
    path = "/api/v1/items",
    tag = "Items",
    request_body = UpsertItemRequest,
    responses(
        (status = 200, description = "Item upserted", body = DemoItem),
        (status = 400, description = "Invalid input", body = crate::error::ValidationErrorResponse),
        (status = 500, description = "Database or configuration error")
    )
)]
#[instrument(skip(state))]
pub async fn upsert_item(
    State(state): State<AppState>,
    Json(payload): Json<UpsertItemRequest>,
) -> Result<Json<DemoItem>, AppError> {
    if let Err(validation_errors) = payload.validate() {
        tracing::warn!(
            validation_errors = %validation_errors,
            "Item validation failed"
        );
        return Err(AppError::Validation(validation_errors.to_string()));
    }

    let pool = require_pool(&state)?;

    let item = sqlx::query_as::<_, DemoItem>(
        "INSERT INTO demo_items (key, value) VALUES ($1, $2) \
         ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now() \
         RETURNING id, key, value, updated_at",
    )
    .bind(&payload.key)
    .bind(&payload.value)
    .fetch_one(pool)
    .await
    .map_err(|e| database_error("upsert demo_item", e))?;

    tracing::info!(
        item_id = item.id,
        item_key = %item.key,
        "Item upserted"
    );

    Ok(Json(item))
}

/// Fetch a single demo item by its natural key
#[utoipa::path(
    get,
    path = "/api/v1/items/{key}",
    tag = "Items",
    params(
        ("key" = String, Path, description = "Item key")
    ),
    responses(
        (status = 200, description = "Item found", body = DemoItem),
        (status = 404, description = "Item not found"),
        (status = 500, description = "Database or configuration error")
    )
)]
#[instrument(skip(state))]
pub async fn get_item(
    State(state): State<AppState>,
    Path(key): Path<String>,
) -> Result<Json<DemoItem>, AppError> {
    let pool = require_pool(&state)?;

    let item = sqlx::query_as::<_, DemoItem>(
        "SELECT id, key, value, updated_at FROM demo_items WHERE key = $1",
    )
    .bind(&key)
    .fetch_optional(pool)
    .await
    .map_err(|e| database_error("get demo_item", e))?;

    match item {
        Some(item) => Ok(Json(item)),
        None => {
            tracing::warn!(item_key = %key, "Item not found");
            Err(AppError::NotFound(format!("item not found: {}", key)))
        }
    }
}
{%- endif %}
