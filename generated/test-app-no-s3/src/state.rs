use metrics_exporter_prometheus::PrometheusHandle;
use redis::aio::MultiplexedConnection;
/// Application state shared across all handlers
/// Uses dependency injection pattern - accepts pre-configured dependencies
#[derive(Clone)]
pub struct AppState {
    /// Redis multiplexed connection - supports Clone and handles concurrency internally
    /// No need for Arc<RwLock<>> - MultiplexedConnection is already designed for this
    pub redis: MultiplexedConnection,
    /// Prometheus metrics handle for /metrics endpoint
    pub metrics_handle: PrometheusHandle,
}

impl AppState {
    /// Create new AppState with dependency injection
    ///
    /// # Example
    /// ```compile_fail
    /// use redis::Client;
    /// use test_app_no_s3::state::AppState;
    ///
    /// #[tokio::main]
    /// async fn main() -> Result<(), Box<dyn std::error::Error>> {
    ///     let client = Client::open("redis://localhost:6379")?;
    ///     let conn = client.get_multiplexed_async_connection().await?;
    ///     let state = AppState::new(conn, metrics_handle);
    ///     Ok(())
    /// }
    /// ```
    pub fn new(redis: MultiplexedConnection, metrics_handle: PrometheusHandle) -> Self {
        Self {
            redis,
            metrics_handle,
        }
    }
}
