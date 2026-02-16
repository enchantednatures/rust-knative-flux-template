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

    {%- if features contains "kafka" %}
    #[error("Kafka error: {0}")]
    Kafka(#[from] KafkaError),
    {%- endif %}
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
            {%- if features contains "kafka" %}
            AppError::Kafka(ref e) => {
                tracing::error!(error = %e, "Kafka error");
                (StatusCode::INTERNAL_SERVER_ERROR, "Event publishing failed")
            }
            {%- endif %}
        };

        let body = Json(json!({
            "error": error_message,
            "details": self.to_string(),
        }));

        (status, body).into_response()
    }
}

{%- if features contains "kafka" %}
/// Kafka-specific error type with structured context for observability
#[derive(Error, Debug, Clone)]
pub enum KafkaError {
    #[error("Kafka initialization failed: {0}")]
    InitializationFailed(String),

    #[error("Failed to publish event: {0}")]
    PublishFailed(String),

    #[error("Event serialization failed: {0}")]
    SerializationFailed(String),

    /// Broker unreachable error with structured context fields for logging
    /// Contains both the broker URL and detailed reason for failure
    #[error("Kafka broker unreachable at {broker}: {reason}")]
    BrokerUnreachable { broker: String, reason: String },

    #[error("Invalid Kafka configuration: {0}")]
    InvalidConfiguration(String),

    #[error("Kafka topic not found: {0}")]
    TopicNotFound(String),

    #[error("Internal Kafka error: {0}")]
    Internal(String),
}

impl KafkaError {
    /// Creates a BrokerUnreachable error with structured context
    ///
    /// # Arguments
    ///
    /// * `broker` - Broker URL that is unreachable
    /// * `reason` - Detailed reason for failure (e.g., connection refused, timeout)
    pub fn broker_unreachable(broker: impl Into<String>, reason: impl Into<String>) -> Self {
        Self::BrokerUnreachable {
            broker: broker.into(),
            reason: reason.into(),
        }
    }

    /// Returns structured error context as a tuple for logging
    ///
    /// Useful for adding consistent error context to tracing logs
    pub fn context(&self) -> (String, String) {
        match self {
            Self::BrokerUnreachable { broker, reason } => {
                ("broker_unreachable".to_string(), format!("{} ({})", broker, reason))
            }
            Self::PublishFailed(reason) => {
                ("publish_failed".to_string(), reason.clone())
            }
            Self::SerializationFailed(reason) => {
                ("serialization_failed".to_string(), reason.clone())
            }
            Self::InitializationFailed(reason) => {
                ("initialization_failed".to_string(), reason.clone())
            }
            Self::TopicNotFound(topic) => {
                ("topic_not_found".to_string(), topic.clone())
            }
            Self::InvalidConfiguration(reason) => {
                ("invalid_configuration".to_string(), reason.clone())
            }
            Self::Internal(reason) => {
                ("internal_error".to_string(), reason.clone())
            }
        }
    }
}
{%- endif %}
