use axum::body::Bytes;
use axum::extract::{FromRequest, Request};
use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::Value;

use crate::error::CloudEventError;
use crate::metadata::CloudEventMetadata;

#[derive(Debug)]
pub struct CloudEvent<T: DeserializeOwned> {
    pub metadata: CloudEventMetadata,
    pub data: T,
}

impl<T: DeserializeOwned> CloudEvent<T> {
    pub fn new(metadata: CloudEventMetadata, data: T) -> Self {
        Self { metadata, data }
    }

    pub fn id(&self) -> &str {
        &self.metadata.id
    }

    pub fn r#type(&self) -> &str {
        &self.metadata.r#type
    }

    pub fn source(&self) -> &str {
        &self.metadata.source
    }

    pub fn subject(&self) -> Option<&str> {
        self.metadata.subject.as_deref()
    }

    pub fn time(&self) -> Option<&str> {
        self.metadata.time.as_deref()
    }

    pub fn content_type(&self) -> Option<&str> {
        self.metadata.data_content_type.as_deref()
    }

    pub fn into_data(self) -> T {
        self.data
    }

    pub fn into_parts(self) -> (CloudEventMetadata, T) {
        (self.metadata, self.data)
    }
}

#[derive(Deserialize)]
struct RawCloudEvent {
    #[serde(rename = "id")]
    id: String,

    #[serde(rename = "source")]
    source: String,

    #[serde(rename = "type")]
    ce_type: String,

    #[serde(rename = "specversion", default = "default_spec_version")]
    spec_version: String,

    #[serde(rename = "datacontenttype", default)]
    data_content_type: Option<String>,

    #[serde(rename = "dataschema", default)]
    data_schema: Option<String>,

    #[serde(rename = "subject", default)]
    subject: Option<String>,

    #[serde(rename = "time", default)]
    time: Option<String>,

    #[serde(rename = "data")]
    data: Option<Value>,
}

fn default_spec_version() -> String {
    "1.0".to_string()
}

impl<S, T> FromRequest<S> for CloudEvent<T>
where
    T: DeserializeOwned + Send,
    S: Send + Sync,
{
    type Rejection = CloudEventError;

    async fn from_request(req: Request, state: &S) -> Result<Self, Self::Rejection> {
        let (parts, body) = req.into_parts();
        let headers = &parts.headers;

        // Binary mode is signalled by any CloudEvents header, not just `ce-id`:
        // a request that carries `ce-source`/`ce-type` but forgot `ce-id` is a
        // malformed binary event, and must report the missing header instead of
        // falling back to structured mode and failing on the body as JSON.
        let is_binary_mode = headers.keys().any(|name| name.as_str().starts_with("ce-"));

        if is_binary_mode {
            extract_binary_mode(parts, body, state).await
        } else {
            extract_structured_mode(parts, body, state).await
        }
    }
}

async fn extract_structured_mode<S, T>(
    parts: http::request::Parts,
    body: axum::body::Body,
    state: &S,
) -> Result<CloudEvent<T>, CloudEventError>
where
    T: DeserializeOwned + Send,
    S: Send + Sync,
{
    let bytes = Bytes::from_request(Request::from_parts(parts, body), state)
        .await
        .map_err(|e| CloudEventError::BodyRead(e.to_string()))?;

    let raw: RawCloudEvent = serde_json::from_slice(&bytes)?;

    if raw.id.is_empty() {
        return Err(CloudEventError::MissingField("id"));
    }
    if raw.source.is_empty() {
        return Err(CloudEventError::MissingField("source"));
    }
    if raw.ce_type.is_empty() {
        return Err(CloudEventError::MissingField("type"));
    }

    let data = match raw.data {
        Some(value) => serde_json::from_value(value)?,
        None => serde_json::from_value(Value::Null)?,
    };

    let metadata = CloudEventMetadata {
        id: raw.id,
        source: raw.source,
        r#type: raw.ce_type,
        spec_version: raw.spec_version,
        data_content_type: raw.data_content_type,
        data_schema: raw.data_schema,
        subject: raw.subject,
        time: raw.time,
    };

    Ok(CloudEvent::new(metadata, data))
}

async fn extract_binary_mode<S, T>(
    parts: http::request::Parts,
    body: axum::body::Body,
    state: &S,
) -> Result<CloudEvent<T>, CloudEventError>
where
    T: DeserializeOwned + Send,
    S: Send + Sync,
{
    let headers = &parts.headers;

    let metadata = CloudEventMetadata::from_headers(headers)?;

    let bytes = Bytes::from_request(Request::from_parts(parts, body), state)
        .await
        .map_err(|e| CloudEventError::BodyRead(e.to_string()))?;

    let data: T = serde_json::from_slice(&bytes)?;

    Ok(CloudEvent::new(metadata, data))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::extract::FromRequest;
    use axum::http::Request;
    use serde::Deserialize;

    #[derive(Debug, Deserialize, PartialEq)]
    struct Ping {
        message: String,
    }

    fn structured(body: serde_json::Value) -> Request<Body> {
        Request::builder()
            .method("POST")
            .header("content-type", "application/cloudevents+json")
            .body(Body::from(body.to_string()))
            .expect("valid request")
    }

    async fn extract<T: DeserializeOwned + Send>(
        req: Request<Body>,
    ) -> Result<CloudEvent<T>, CloudEventError> {
        CloudEvent::<T>::from_request(req, &()).await
    }

    #[tokio::test]
    async fn structured_mode_parses_metadata_and_data() {
        let req = structured(serde_json::json!({
            "specversion": "1.0",
            "id": "evt-1",
            "source": "/api/v1/ping",
            "type": "com.example.ping",
            "datacontenttype": "application/json",
            "dataschema": "https://schema/ping",
            "subject": "pings/1",
            "time": "2026-01-02T03:04:05Z",
            "data": { "message": "pong" }
        }));

        let event = extract::<Ping>(req).await.expect("structured event");

        assert_eq!(event.id(), "evt-1");
        assert_eq!(event.source(), "/api/v1/ping");
        assert_eq!(event.r#type(), "com.example.ping");
        assert_eq!(event.subject(), Some("pings/1"));
        assert_eq!(event.time(), Some("2026-01-02T03:04:05Z"));
        assert_eq!(event.content_type(), Some("application/json"));
        assert_eq!(
            event.data,
            Ping {
                message: "pong".to_string()
            }
        );
        assert_eq!(
            event.metadata.data_schema.as_deref(),
            Some("https://schema/ping")
        );
    }

    #[tokio::test]
    async fn structured_mode_defaults_specversion_when_omitted() {
        let req = structured(serde_json::json!({
            "id": "evt-2",
            "source": "src",
            "type": "com.example.ping",
            "data": { "message": "hi" }
        }));

        let event = extract::<Ping>(req).await.expect("structured event");
        assert_eq!(event.metadata.spec_version, "1.0");
    }

    #[tokio::test]
    async fn structured_mode_rejects_invalid_json() {
        let req = Request::builder()
            .method("POST")
            .body(Body::from("{not json"))
            .expect("valid request");

        match extract::<Ping>(req).await {
            Err(CloudEventError::InvalidJson(_)) => {}
            other => panic!("expected InvalidJson, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn structured_mode_rejects_empty_required_fields() {
        for (field, payload) in [
            (
                "id",
                serde_json::json!({"id": "", "source": "s", "type": "t"}),
            ),
            (
                "source",
                serde_json::json!({"id": "i", "source": "", "type": "t"}),
            ),
            (
                "type",
                serde_json::json!({"id": "i", "source": "s", "type": ""}),
            ),
        ] {
            match extract::<Ping>(structured(payload)).await {
                Err(CloudEventError::MissingField(name)) => assert_eq!(name, field),
                other => panic!("expected MissingField({field}), got {other:?}"),
            }
        }
    }

    #[tokio::test]
    async fn structured_mode_rejects_a_missing_required_field() {
        let req = structured(serde_json::json!({"source": "s", "type": "t"}));

        match extract::<Ping>(req).await {
            Err(CloudEventError::InvalidJson(_)) => {}
            other => panic!("expected InvalidJson for a missing field, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn binary_mode_parses_metadata_from_headers() {
        let req = Request::builder()
            .method("POST")
            .header("ce-id", "evt-3")
            .header("ce-source", "/api/v1/ping")
            .header("ce-type", "com.example.ping")
            .header("ce-specversion", "1.0")
            .header("ce-subject", "pings/3")
            .header("content-type", "application/json")
            .body(Body::from(r#"{"message":"from headers"}"#))
            .expect("valid request");

        let event = extract::<Ping>(req).await.expect("binary event");

        assert_eq!(event.id(), "evt-3");
        assert_eq!(event.source(), "/api/v1/ping");
        assert_eq!(event.r#type(), "com.example.ping");
        assert_eq!(event.subject(), Some("pings/3"));
        assert_eq!(event.time(), None);
        assert_eq!(
            event.data,
            Ping {
                message: "from headers".to_string()
            }
        );
    }

    #[tokio::test]
    async fn binary_mode_reports_missing_required_headers() {
        let req = Request::builder()
            .method("POST")
            .header("ce-source", "/api/v1/ping")
            .header("ce-type", "com.example.ping")
            .body(Body::from(r#"{"message":"x"}"#))
            .expect("valid request");

        match extract::<Ping>(req).await {
            Err(CloudEventError::MissingHeader(name)) => assert_eq!(name, "ce-id"),
            other => panic!("expected MissingHeader(ce-id), got {other:?}"),
        }
    }

    #[tokio::test]
    async fn binary_mode_rejects_a_body_that_does_not_match_the_payload_type() {
        let req = Request::builder()
            .method("POST")
            .header("ce-id", "evt-4")
            .header("ce-source", "/api/v1/ping")
            .header("ce-type", "com.example.ping")
            .body(Body::from(r#"{"unexpected":true}"#))
            .expect("valid request");

        match extract::<Ping>(req).await {
            Err(CloudEventError::InvalidJson(_)) => {}
            other => panic!("expected InvalidJson, got {other:?}"),
        }
    }

    #[test]
    fn accessors_and_into_parts_expose_metadata_and_data() {
        let metadata = CloudEventMetadata::new("id", "src", "com.example.ping");
        let event = CloudEvent::new(
            metadata,
            Ping {
                message: "x".to_string(),
            },
        );

        assert_eq!(event.id(), "id");
        assert_eq!(event.source(), "src");
        assert_eq!(event.r#type(), "com.example.ping");

        let (meta, data) = event.into_parts();
        assert_eq!(meta.id, "id");
        assert_eq!(data.message, "x");
    }
}
