use http::HeaderMap;
use serde::Deserialize;

use crate::error::CloudEventError;
use crate::headers::{
    CE_DATACONTENTTYPE, CE_DATASCHEMA, CE_ID, CE_SOURCE, CE_SPECVERSION, CE_SUBJECT, CE_TIME,
    CE_TYPE,
};

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CloudEventMetadata {
    #[serde(rename = "id")]
    pub id: String,

    #[serde(rename = "source")]
    pub source: String,

    #[serde(rename = "type")]
    pub r#type: String,

    #[serde(rename = "specversion", default = "default_spec_version")]
    pub spec_version: String,

    #[serde(rename = "datacontenttype", default)]
    pub data_content_type: Option<String>,

    #[serde(rename = "dataschema", default)]
    pub data_schema: Option<String>,

    #[serde(rename = "subject", default)]
    pub subject: Option<String>,

    #[serde(rename = "time", default)]
    pub time: Option<String>,
}

fn default_spec_version() -> String {
    "1.0".to_string()
}

impl CloudEventMetadata {
    pub fn new(
        id: impl Into<String>,
        source: impl Into<String>,
        r#type: impl Into<String>,
    ) -> Self {
        Self {
            id: id.into(),
            source: source.into(),
            r#type: r#type.into(),
            spec_version: "1.0".to_string(),
            data_content_type: None,
            data_schema: None,
            subject: None,
            time: None,
        }
    }

    pub fn from_headers(headers: &HeaderMap) -> Result<Self, CloudEventError> {
        let id = get_required_header(headers, CE_ID)?;
        let source = get_required_header(headers, CE_SOURCE)?;
        let r#type = get_required_header(headers, CE_TYPE)?;
        let spec_version = get_header(headers, CE_SPECVERSION).unwrap_or_else(|| "1.0".to_string());

        Ok(Self {
            id,
            source,
            r#type,
            spec_version,
            data_content_type: get_header(headers, CE_DATACONTENTTYPE),
            data_schema: get_header(headers, CE_DATASCHEMA),
            subject: get_header(headers, CE_SUBJECT),
            time: get_header(headers, CE_TIME),
        })
    }

    pub fn type_matches(&self, prefix: &str) -> bool {
        self.r#type.starts_with(prefix)
    }
}

fn get_required_header(headers: &HeaderMap, name: &str) -> Result<String, CloudEventError> {
    headers
        .get(name)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string())
        .ok_or_else(|| CloudEventError::MissingHeader(name.to_string()))
}

fn get_header(headers: &HeaderMap, name: &str) -> Option<String> {
    headers
        .get(name)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use http::HeaderValue;

    fn headers() -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(CE_ID, HeaderValue::from_static("evt-1"));
        headers.insert(CE_SOURCE, HeaderValue::from_static("/api/v1/things"));
        headers.insert(
            CE_TYPE,
            HeaderValue::from_static("com.example.thing.created"),
        );
        headers.insert(CE_SPECVERSION, HeaderValue::from_static("1.0"));
        headers.insert(
            CE_DATACONTENTTYPE,
            HeaderValue::from_static("application/json"),
        );
        headers.insert(
            CE_DATASCHEMA,
            HeaderValue::from_static("https://schema/thing"),
        );
        headers.insert(CE_SUBJECT, HeaderValue::from_static("things/1"));
        headers.insert(CE_TIME, HeaderValue::from_static("2026-01-02T03:04:05Z"));
        headers
    }

    #[test]
    fn from_headers_parses_every_optional_field() {
        let meta = CloudEventMetadata::from_headers(&headers()).expect("valid headers");

        assert_eq!(meta.id, "evt-1");
        assert_eq!(meta.source, "/api/v1/things");
        assert_eq!(meta.r#type, "com.example.thing.created");
        assert_eq!(meta.spec_version, "1.0");
        assert_eq!(meta.data_content_type.as_deref(), Some("application/json"));
        assert_eq!(meta.data_schema.as_deref(), Some("https://schema/thing"));
        assert_eq!(meta.subject.as_deref(), Some("things/1"));
        assert_eq!(meta.time.as_deref(), Some("2026-01-02T03:04:05Z"));
    }

    #[test]
    fn from_headers_defaults_spec_version_and_leaves_optional_fields_empty() {
        let mut headers = HeaderMap::new();
        headers.insert(CE_ID, HeaderValue::from_static("evt-2"));
        headers.insert(CE_SOURCE, HeaderValue::from_static("src"));
        headers.insert(CE_TYPE, HeaderValue::from_static("t"));

        let meta = CloudEventMetadata::from_headers(&headers).expect("valid headers");

        assert_eq!(meta.spec_version, "1.0");
        assert!(meta.data_content_type.is_none());
        assert!(meta.data_schema.is_none());
        assert!(meta.subject.is_none());
        assert!(meta.time.is_none());
    }

    #[test]
    fn from_headers_reports_the_missing_required_header() {
        for (missing, expected) in [
            (CE_ID, "ce-id"),
            (CE_SOURCE, "ce-source"),
            (CE_TYPE, "ce-type"),
        ] {
            let mut headers = headers();
            headers.remove(missing);

            match CloudEventMetadata::from_headers(&headers) {
                Err(CloudEventError::MissingHeader(name)) => assert_eq!(name, expected),
                other => panic!("expected MissingHeader({expected}), got {other:?}"),
            }
        }
    }

    #[test]
    fn from_headers_ignores_non_utf8_header_values() {
        let mut headers = headers();
        headers.insert(CE_SUBJECT, HeaderValue::from_bytes(b"\xff\xfe").unwrap());

        let meta = CloudEventMetadata::from_headers(&headers).expect("valid headers");
        assert!(
            meta.subject.is_none(),
            "invalid utf-8 must be treated as absent"
        );
    }

    #[test]
    fn type_matches_uses_the_event_type_prefix() {
        let meta = CloudEventMetadata::new("id", "src", "com.example.thing.created");

        assert!(meta.type_matches("com.example."));
        assert!(!meta.type_matches("dev.knative."));
        assert!(meta.type_matches(""));
    }
}
