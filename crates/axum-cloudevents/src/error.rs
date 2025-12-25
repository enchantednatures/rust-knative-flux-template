use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;

#[derive(Debug, thiserror::Error)]
pub enum CloudEventError {
    #[error("Failed to read request body: {0}")]
    BodyRead(String),

    #[error("Invalid JSON: {0}")]
    InvalidJson(#[from] serde_json::Error),

    #[error("Missing required field: {0}")]
    MissingField(&'static str),

    #[error("Unknown event type: {0}")]
    UnknownEventType(String),
}

impl IntoResponse for CloudEventError {
    fn into_response(self) -> Response {
        let (status, message) = match &self {
            CloudEventError::BodyRead(msg) => (StatusCode::BAD_REQUEST, msg.clone()),
            CloudEventError::InvalidJson(e) => (StatusCode::BAD_REQUEST, e.to_string()),
            CloudEventError::MissingField(field) => {
                (StatusCode::BAD_REQUEST, format!("Missing field: {}", field))
            }
            CloudEventError::UnknownEventType(t) => {
                (StatusCode::BAD_REQUEST, format!("Unknown event type: {}", t))
            }
        };

        tracing::error!(error = %self, "CloudEvent extraction failed");

        (status, Json(serde_json::json!({ "error": message }))).into_response()
    }
}
