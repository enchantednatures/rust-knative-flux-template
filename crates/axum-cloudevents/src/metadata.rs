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
