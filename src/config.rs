use figment::{
    Figment,
    providers::{Env, Format, Serialized, Toml},
};
use serde::{Deserialize, Serialize};

{%- if features contains "s3" %}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct S3Config {
    /// S3-compatible endpoint (required for MinIO)
    pub endpoint: String,
    /// Bucket name
    pub bucket: String,
    /// AWS region (use "us-east-1" for MinIO)
    pub region: String,
    // Credentials via AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY env vars
}
{%- endif %}

{%- if features contains "kafka" %}
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct KafkaConfig {
    /// Kafka broker URL (e.g., "kafka.kafka.svc.cluster.local:9092")
    /// REQUIRED - must be provided via config file or APP__KAFKA__BROKER_URL
    pub broker_url: String,
    /// Kafka topic name for events
    /// REQUIRED - must be provided via config file or APP__KAFKA__TOPIC
    pub topic: String,
    /// CloudEvents event name/type (e.g., "com.example.service.event.published")
    /// REQUIRED - must be provided via config file or APP__KAFKA__EVENT_NAME
    pub event_name: String,
    /// Compression codec: "snappy", "gzip", "lz4", "zstd", or "none"
    #[serde(default = "default_compression")]
    pub compression: String,
    /// Linger time in milliseconds (batches messages up to this duration)
    #[serde(default = "default_linger_ms")]
    pub linger_ms: u32,
    /// Number of retries for failed sends
    #[serde(default = "default_retries")]
    pub retries: u32,
    /// Request timeout in milliseconds
    #[serde(default = "default_timeout_ms")]
    pub timeout_ms: u32,
}

fn default_compression() -> String {
    "snappy".into()
}

fn default_linger_ms() -> u32 {
    5
}

fn default_retries() -> u32 {
    3
}

fn default_timeout_ms() -> u32 {
    10000
}
{%- endif %}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Config {
    pub server: ServerConfig,
    pub redis: RedisConfig,
    pub telemetry: TelemetryConfig,
    {%- if features contains "s3" %}
     pub s3: S3Config,
     {%- endif %}
     {%- if features contains "kafka" %}
     pub kafka: Option<KafkaConfig>,
     {%- endif %}
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ServerConfig {
    pub host: String,
    pub port: u16,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct RedisConfig {
    /// Redis connection URL
    /// Format: redis://[:password@]host[:port][/db]
    /// MUST be provided via config file or APP__REDIS__URL environment variable
    pub url: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct TelemetryConfig {
    /// OTLP endpoint for traces (optional)
    /// If not set, traces will only be logged
    pub otlp_endpoint: Option<String>,
    pub service_name: String,
    pub log_level: String,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            server: ServerConfig {
                host: "0.0.0.0".into(),
                port: 8080,
            },
            redis: RedisConfig {
                url: "redis://localhost:6379".into(),
            },
            telemetry: TelemetryConfig {
                otlp_endpoint: None,
                service_name: "{{ project_name }}".into(),
                log_level: "info".into(),
            },
            {%- if features contains "s3" %}
            s3: S3Config {
                endpoint: "http://localhost:9000".into(),
                bucket: "data".into(),
                region: "us-east-1".into(),
             },
             {%- endif %}
             {%- if features contains "kafka" %}
             kafka: None,
             {%- endif %}
        }
    }
}

impl Config {
    /// Load configuration with the following priority (highest to lowest):
    /// 1. Environment variables (APP__* prefix)
    /// 2. Environment-specific config file (config/{env}.toml)
    /// 3. Default values
    ///
    /// # Example Environment Variables
    /// - APP__SERVER__PORT=9000
     /// - APP__REDIS__URL=redis://:password@host:6379/0
     /// - APP__TELEMETRY__OTLP_ENDPOINT=http://otel-collector:4317
     {%- if features contains "kafka" %}
     /// - APP__KAFKA__BROKER_URL=kafka.kafka.svc.cluster.local:9092
     /// - APP__KAFKA__TOPIC=events
     /// - APP__KAFKA__EVENT_NAME=com.example.service.event.published
     {%- endif %}
    #[allow(clippy::result_large_err)]
    pub fn load() -> Result<Self, figment::Error> {
        let env = std::env::var("APP_ENV").unwrap_or_else(|_| "development".into());

        let config: Config = Figment::new()
            // 1. Start with defaults
            .merge(Serialized::defaults(Config::default()))
            // 2. Merge environment-specific file
            .merge(Toml::file(format!("config/{}.toml", env)).nested())
            // 3. Override with environment variables (highest priority)
            // APP__SERVER__PORT=9000 -> server.port = 9000
            .merge(Env::prefixed("APP__").split("__"))
            .extract()?;

        // Early validation: ensure critical values are present
        config.validate()?;

        Ok(config)
    }

    /// Validate configuration
    /// Fails fast if required values are missing or invalid
    #[allow(clippy::result_large_err)]
    fn validate(&self) -> Result<(), figment::Error> {
        if self.redis.url.is_empty() {
            return Err(figment::Error::from(
                "redis.url must be set (via config file or APP__REDIS__URL)",
            ));
        }

        if self.server.port == 0 {
            return Err(figment::Error::from("server.port must be non-zero"));
        }

        {%- if features contains "s3" %}

        if self.s3.endpoint.is_empty() {
            return Err(figment::Error::from(
                "s3.endpoint must be set (via config file or APP__S3__ENDPOINT)",
            ));
        }

        if self.s3.bucket.is_empty() {
            return Err(figment::Error::from(
                "s3.bucket must be set (via config file or APP__S3__BUCKET)",
            ));
         }
         {%- endif %}

         {%- if features contains "kafka" %}
         if let Some(kafka) = &self.kafka {
             kafka.validate()?;
         }
         {%- endif %}

        Ok(())
     }
 }

 {%- if features contains "kafka" %}
 impl KafkaConfig {
    /// Validate Kafka configuration
    /// Ensures required fields are non-empty and optional fields are within valid ranges
    #[allow(clippy::result_large_err)]
    pub fn validate(&self) -> Result<(), figment::Error> {
        if self.broker_url.is_empty() {
            return Err(figment::Error::from(
                "kafka.broker_url must be set (via config file or APP__KAFKA__BROKER_URL)",
            ));
        }

        if self.topic.is_empty() {
            return Err(figment::Error::from(
                "kafka.topic must be set (via config file or APP__KAFKA__TOPIC)",
            ));
        }

        if self.event_name.is_empty() {
            return Err(figment::Error::from(
                "kafka.event_name must be set (via config file or APP__KAFKA__EVENT_NAME)",
            ));
        }

        // Validate compression codec
        match self.compression.as_str() {
            "snappy" | "gzip" | "lz4" | "zstd" | "none" => {}
            _ => {
                return Err(figment::Error::from(
                    "kafka.compression must be one of: snappy, gzip, lz4, zstd, none",
                ));
            }
        }

        // Validate linger_ms range (0-60000 ms = 0-60 seconds)
        if self.linger_ms > 60000 {
            return Err(figment::Error::from(
                "kafka.linger_ms must be <= 60000",
            ));
        }

        // Validate timeout_ms range (1000-300000 ms = 1-300 seconds)
        if self.timeout_ms < 1000 || self.timeout_ms > 300000 {
            return Err(figment::Error::from(
                "kafka.timeout_ms must be between 1000 and 300000",
            ));
        }

        // Validate event_name format (should match CloudEvents type field conventions)
        // Format: reverse-domain notation, alphanumeric and dots only
        if !self.event_name.chars().all(|c| c.is_alphanumeric() || c == '.') {
            return Err(figment::Error::from(
                "kafka.event_name must contain only alphanumeric characters and dots (e.g., 'com.example.service.event')",
            ));
        }

         Ok(())
     }
 }
 {%- endif %}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_config() {
        let config = Config::default();
        assert_eq!(config.server.port, 8080);
        assert_eq!(config.server.host, "0.0.0.0");
    }

    #[test]
    fn test_validation_fails_on_empty_redis_url() {
        let mut config = Config::default();
        config.redis.url = String::new();
        assert!(config.validate().is_err());
    }
}
