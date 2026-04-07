use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use serde::Serialize;
use serde_json::json;
use thiserror::Error;
use validator::ValidationErrors;

/// Application-wide error type
#[derive(Error, Debug)]
pub enum AppError {
    #[error("Redis error: {0}")]
    Redis(#[from] redis::RedisError),

    #[error("Configuration error: {0}")]
    Config(String),

    #[error("Internal server error: {0}")]
    Internal(String),

    #[error("Validation error: {0}")]
    Validation(String),

    #[error("Rate limit exceeded")]
    RateLimit,

    {%- if feature_kafka %}
    #[error("Kafka error: {0}")]
    Kafka(#[from] KafkaError),
    {%- endif %}
}

impl From<figment::Error> for AppError {
    fn from(err: figment::Error) -> Self {
        AppError::Config(err.to_string())
    }
}

impl From<ValidationErrors> for AppError {
    fn from(err: ValidationErrors) -> Self {
        AppError::Validation(err.to_string())
    }
}

/// Response structure for validation errors
#[derive(Serialize)]
pub struct ValidationErrorResponse {
    pub error: String,
    pub details: Vec<String>,
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, error_message, details) = match &self {
            AppError::Redis(ref e) => {
                tracing::error!(error = %e, error_type = "redis", "Redis error");
                (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "Service unavailable",
                    vec![e.to_string()],
                )
            }
            AppError::Config(ref e) => {
                tracing::error!(error = %e, error_type = "config", "Configuration error");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Configuration error",
                    vec![e.to_string()],
                )
            }
            AppError::Internal(ref e) => {
                tracing::error!(error = %e, error_type = "internal", "Internal error");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Internal server error",
                    vec![e.to_string()],
                )
            }
            AppError::Validation(ref e) => {
                tracing::warn!(error = %e, error_type = "validation", "Validation error");
                (
                    StatusCode::BAD_REQUEST,
                    "Invalid input",
                    vec![e.to_string()],
                )
            }
            AppError::RateLimit => {
                tracing::warn!(error_type = "rate_limit", "Rate limit exceeded");
                (
                    StatusCode::TOO_MANY_REQUESTS,
                    "Rate limit exceeded",
                    vec!["Too many requests. Please try again later.".to_string()],
                )
            }
            {%- if feature_kafka %}
            AppError::Kafka(ref e) => {
                tracing::error!(error = %e, error_type = "kafka", "Kafka error");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Event publishing failed",
                    vec![e.to_string()],
                )
            }
            {%- endif %}
        };

        let body = Json(json!({
            "error": error_message,
            "details": details,
            "request_id": None::<String>, // Will be populated by middleware
        }));

        (status, body).into_response()
    }
}

{%- if feature_kafka %}
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
