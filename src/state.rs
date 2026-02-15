{%- if feature_s3 -%}
use opendal::Operator;
use redis::aio::MultiplexedConnection;
{%- else %}
use redis::aio::MultiplexedConnection;
{%- endif %}
{%- if feature_kafka %}
use crate::handlers::kafka::KafkaPublisher;
use std::sync::Arc;
{%- endif %}
use metrics_exporter_prometheus::PrometheusHandle;
/// Application state shared across all handlers
/// Uses dependency injection pattern - accepts pre-configured dependencies
#[derive(Clone)]
pub struct AppState {
    /// Redis multiplexed connection - supports Clone and handles concurrency internally
    /// No need for Arc<RwLock<>> - MultiplexedConnection is already designed for this
    pub redis: MultiplexedConnection,
    {%- if feature_s3 %}
    /// S3-compatible storage operator (MinIO/S3 via OpenDAL)
    pub storage: Operator,
    {%- endif %}
    {%- if feature_kafka %}
    /// Kafka publisher for event publishing
    pub kafka_publisher: Option<Arc<KafkaPublisher>>,
    {%- endif %}
    /// Prometheus metrics handle for /metrics endpoint
    pub metrics_handle: PrometheusHandle,
}

impl AppState {
    /// Create new AppState with dependency injection
    ///
    /// # Example
    /// ```compile_fail
    /// use redis::Client;
    /// use {{ crate_name }}::state::AppState;
    ///
    /// #[tokio::main]
    /// async fn main() -> Result<(), Box<dyn std::error::Error>> {
    ///     let client = Client::open("redis://localhost:6379")?;
    ///     let conn = client.get_multiplexed_async_connection().await?;
    ///     let state = AppState::new(conn{%- if feature_s3 %}, storage{%- endif %}{%- if feature_kafka %}, kafka_publisher{%- endif %}, metrics_handle);
    ///     Ok(())
    /// }
    /// ```
    {%- if feature_s3 %}
    {%- if feature_kafka %}
    pub fn new(redis: MultiplexedConnection, storage: Operator, kafka_publisher: Option<Arc<KafkaPublisher>>, metrics_handle: PrometheusHandle) -> Self {
        Self { redis, storage, kafka_publisher, metrics_handle }
    }
    {%- else %}
    pub fn new(redis: MultiplexedConnection, storage: Operator, metrics_handle: PrometheusHandle) -> Self {
        Self { redis, storage, metrics_handle }
    }
    {%- endif %}
    {%- else %}
    {%- if feature_kafka %}
    pub fn new(redis: MultiplexedConnection, kafka_publisher: Option<Arc<KafkaPublisher>>, metrics_handle: PrometheusHandle) -> Self {
        Self { redis, kafka_publisher, metrics_handle }
    }
    {%- else %}
    pub fn new(redis: MultiplexedConnection, metrics_handle: PrometheusHandle) -> Self {
        Self { redis, metrics_handle }
    }
    {%- endif %}
    {%- endif %}
}
