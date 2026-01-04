use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use serde_json::json;
use thiserror::Error;

/// Application-wide error type
#[derive(Error, Debug)]
pub enum AppError {
    #[error("Redis error: {0}")]
    Redis(#[from] redis::RedisError),

    #[error("Configuration error: {0}")]
    Config(String),

    #[error("Internal server error: {0}")]
    Internal(String),

    {% if enable_kafka %}
    #[error("Kafka error: {0}")]
    Kafka(#[from] KafkaError),
    {% endif %}
}

impl From<figment::Error> for AppError {
    fn from(err: figment::Error) -> Self {
        AppError::Config(err.to_string())
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, error_message) = match self {
            AppError::Redis(ref e) => {
                tracing::error!(error = %e, "Redis error");
                (StatusCode::SERVICE_UNAVAILABLE, "Service unavailable")
            }
            AppError::Config(ref e) => {
                tracing::error!(error = %e, "Configuration error");
                (StatusCode::INTERNAL_SERVER_ERROR, "Configuration error")
            }
            AppError::Internal(ref e) => {
                tracing::error!(error = %e, "Internal error");
                (StatusCode::INTERNAL_SERVER_ERROR, "Internal server error")
            }
            {% if enable_kafka %}
            AppError::Kafka(ref e) => {
                tracing::error!(error = %e, "Kafka error");
                (StatusCode::INTERNAL_SERVER_ERROR, "Event publishing failed")
            }
            {% endif %}
        };

        let body = Json(json!({
            "error": error_message,
            "details": self.to_string(),
        }));

        (status, body).into_response()
    }
}

{% if enable_kafka %}
/// Kafka-specific error type
#[derive(Error, Debug)]
pub enum KafkaError {
    #[error("Kafka initialization failed: {0}")]
    InitializationFailed(String),

    #[error("Failed to publish event: {0}")]
    PublishFailed(String),

    #[error("Event serialization failed: {0}")]
    SerializationFailed(String),

    #[error("Kafka broker unreachable at {broker}: {reason}")]
    BrokerUnreachable { broker: String, reason: String },

    #[error("Invalid Kafka configuration: {0}")]
    InvalidConfiguration(String),

    #[error("Kafka topic not found: {0}")]
    TopicNotFound(String),

    #[error("Internal Kafka error: {0}")]
    Internal(String),
}
{% endif %}
