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

    #[error("Missing required header: {0}")]
    MissingHeader(String),

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
            CloudEventError::MissingHeader(header) => (
                StatusCode::BAD_REQUEST,
                format!("Missing header: {}", header),
            ),
            CloudEventError::UnknownEventType(t) => (
                StatusCode::BAD_REQUEST,
                format!("Unknown event type: {}", t),
            ),
        };

        tracing::error!(error = %self, "CloudEvent extraction failed");

        (status, Json(serde_json::json!({ "error": message }))).into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::to_bytes;

    async fn status_and_body(err: CloudEventError) -> (StatusCode, serde_json::Value) {
        let response = err.into_response();
        let status = response.status();
        let bytes = to_bytes(response.into_body(), 1024 * 16)
            .await
            .expect("body bytes");
        let json = serde_json::from_slice(&bytes).expect("json error body");
        (status, json)
    }

    #[tokio::test]
    async fn missing_header_maps_to_400() {
        let (status, body) =
            status_and_body(CloudEventError::MissingHeader("ce-id".to_string())).await;

        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(body["error"], "Missing header: ce-id");
    }

    #[tokio::test]
    async fn missing_field_maps_to_400() {
        let (status, body) = status_and_body(CloudEventError::MissingField("source")).await;

        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(body["error"], "Missing field: source");
    }

    #[tokio::test]
    async fn invalid_json_maps_to_400_with_the_parser_message() {
        let err: CloudEventError = serde_json::from_str::<serde_json::Value>("{nope")
            .expect_err("invalid json")
            .into();
        let (status, body) = status_and_body(err).await;

        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert!(
            !body["error"].as_str().unwrap_or_default().is_empty(),
            "expected a parser message, got {body}"
        );
    }

    #[tokio::test]
    async fn unknown_event_type_and_body_read_errors_map_to_400() {
        let (status, body) =
            status_and_body(CloudEventError::UnknownEventType("x.y".to_string())).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(body["error"], "Unknown event type: x.y");

        let (status, body) = status_and_body(CloudEventError::BodyRead("boom".to_string())).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(body["error"], "boom");
    }
}
