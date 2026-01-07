use axum::body::Bytes;
use axum::extract::{FromRequest, Request};
use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::Value;

use crate::error::CloudEventError;
use crate::headers::CE_ID;
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

        let is_binary_mode = headers.contains_key(CE_ID);

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
