use axum::{Json, extract::State, http::StatusCode};
use serde::Serialize;
use tracing::instrument;
use utoipa::ToSchema;

use crate::state::AppState;

#[derive(Serialize, ToSchema)]
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
/// {%- if enable_kafka_publishing %}
/// Also verifies Kafka broker connectivity if event publishing is enabled.
/// {%- endif %}
/// If Redis is unreachable, returns 503 Service Unavailable.
/// {%- if enable_kafka_publishing %}
/// If Kafka broker is unreachable and event publishing is enabled, returns 503.
/// {%- endif %}
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

    match redis::cmd("PING").query_async::<_, String>(&mut conn).await {
        Ok(_) => {
            {%- if enable_kafka_publishing %}
            // If Kafka publishing is enabled, also check broker connectivity
            if let Some(publisher) = &state.kafka_publisher {
                match publisher.health_check().await {
                    Ok(_) => Ok(Json(HealthResponse {
                        status: "ready".into(),
                    })),
                    Err(e) => {
                        tracing::error!(error = %e, "Kafka health check failed");
                        Err((
                            StatusCode::SERVICE_UNAVAILABLE,
                            Json(HealthResponse {
                                status: format!("kafka unavailable: {}", e),
                            }),
                        ))
                    }
                }
            } else {
                // Kafka not configured, Redis check is sufficient
                Ok(Json(HealthResponse {
                    status: "ready".into(),
                }))
            }
            {%- else %}
            Ok(Json(HealthResponse {
                status: "ready".into(),
            }))
            {%- endif %}
        }
        Err(e) => {
            tracing::error!(error = %e, "Redis health check failed");
            Err((
                StatusCode::SERVICE_UNAVAILABLE,
                Json(HealthResponse {
                    status: format!("redis unavailable: {}", e),
                }),
            ))
        }
    }
}
