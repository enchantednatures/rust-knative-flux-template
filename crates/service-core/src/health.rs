use axum::{
    Json,
    extract::State,
    http::{StatusCode, header},
    response::IntoResponse,
};
use serde::{Deserialize, Serialize};
use tracing::instrument;
use utoipa::ToSchema;

use crate::state::AppState;

#[derive(Clone, Serialize, Deserialize, ToSchema)]
pub struct HealthResponse {
    pub status: String,
}

/// Liveness probe - is the process alive?
///
/// Returns 200 OK if the server can respond.
/// No dependency checks - just confirms the process is running.
///
/// Kubernetes will restart the pod if this fails.
#[utoipa::path(
    get,
    path = "/health/live",
    tag = "Health",
    responses(
        (status = 200, description = "Service is alive", body = HealthResponse)
    )
)]
#[instrument(level = "debug")]
pub async fn liveness() -> Json<HealthResponse> {
    Json(HealthResponse {
        status: "alive".into(),
    })
}

/// Readiness probe - can the service handle traffic?
///
/// Checks Redis connectivity with PING before returning 200 OK.
/// When the corresponding features are enabled it also probes PostgreSQL
/// (`SELECT 1`) and Kafka broker connectivity.
/// If Redis is unreachable, returns 503 Service Unavailable. The optional
/// dependency checks return 503 on failure or timeout.
///
/// Kubernetes will remove the pod from Service endpoints if this fails,
/// but will NOT restart the pod.
#[utoipa::path(
    get,
    path = "/health/ready",
    tag = "Health",
    responses(
        (status = 200, description = "Service is ready", body = HealthResponse),
        (status = 503, description = "Service unavailable", body = HealthResponse)
    )
)]
#[instrument(level = "debug", skip(state))]
pub async fn readiness(
    State(state): State<AppState>,
) -> Result<Json<HealthResponse>, (StatusCode, Json<HealthResponse>)> {
    // Clone the multiplexed connection (cheap operation)
    let mut conn = state.redis.clone();

    if let Err(e) = redis::cmd("PING").query_async::<_, String>(&mut conn).await {
        tracing::error!(error = %e, "Redis health check failed");
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            Json(HealthResponse {
                status: format!("redis unavailable: {}", e),
            }),
        ));
    }

    #[cfg(feature = "postgres")]
    {
        // A lazy pool may hide an unreachable database until first use; probe it
        // here, bounded to 2s so a hung database cannot stall the probe past the
        // kubelet's own timeout.
        if let Some(pool) = &state.postgres {
            let ping = sqlx::query_scalar::<_, i32>("SELECT 1").fetch_one(pool.as_ref());
            match tokio::time::timeout(std::time::Duration::from_secs(2), ping).await {
                Ok(Ok(_)) => {}
                Ok(Err(e)) => {
                    tracing::error!(error = %e, "PostgreSQL health check failed");
                    return Err((
                        StatusCode::SERVICE_UNAVAILABLE,
                        Json(HealthResponse {
                            status: format!("postgres unavailable: {}", e),
                        }),
                    ));
                }
                Err(_) => {
                    tracing::error!("PostgreSQL health check timed out");
                    return Err((
                        StatusCode::SERVICE_UNAVAILABLE,
                        Json(HealthResponse {
                            status: "postgres unavailable: health check timed out".into(),
                        }),
                    ));
                }
            }
        }
    }

    #[cfg(feature = "kafka")]
    {
        // If Kafka publishing is enabled, also check broker connectivity
        if let Some(publisher) = &state.kafka_publisher
            && let Err(e) = publisher.health_check().await
        {
            tracing::error!(error = %e, "Kafka health check failed");
            return Err((
                StatusCode::SERVICE_UNAVAILABLE,
                Json(HealthResponse {
                    status: format!("kafka unavailable: {}", e),
                }),
            ));
        }
    }

    Ok(Json(HealthResponse {
        status: "ready".into(),
    }))
}

/// Prometheus metrics endpoint
///
/// Returns Prometheus metrics in text format for scraping.
/// Metrics include:
/// - HTTP request metrics (via tower-http)
/// - Custom application metrics
/// - Kafka publish counters/histograms when the `kafka` feature is enabled
#[utoipa::path(
    get,
    path = "/metrics",
    tag = "Health",
    responses(
        (status = 200, description = "Prometheus metrics", content_type = "text/plain; version=0.0.4")
    )
)]
#[instrument(level = "info", skip(state))]
pub async fn metrics(State(state): State<AppState>) -> impl IntoResponse {
    let metrics_text = state.metrics_handle.render();

    tracing::info!(
        metrics_length = metrics_text.len(),
        has_content = !metrics_text.is_empty(),
        "Rendering Prometheus metrics"
    );

    (
        StatusCode::OK,
        [(
            header::CONTENT_TYPE,
            "text/plain; version=0.0.4; charset=utf-8",
        )],
        metrics_text,
    )
}
