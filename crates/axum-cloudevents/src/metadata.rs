use serde::Deserialize;

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
    pub fn new(id: impl Into<String>, source: impl Into<String>, r#type: impl Into<String>) -> Self {
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

    pub fn type_matches(&self, prefix: &str) -> bool {
        self.r#type.starts_with(prefix)
    }
}
