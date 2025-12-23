use redis::aio::MultiplexedConnection;

use opendal::Operator;


/// Application state shared across all handlers
/// Uses dependency injection pattern - accepts pre-configured dependencies
#[derive(Clone)]
pub struct AppState {
    /// Redis multiplexed connection - supports Clone and handles concurrency internally
    /// No need for Arc<RwLock<>> - MultiplexedConnection is already designed for this
    pub redis: MultiplexedConnection,
    
    /// S3-compatible storage operator (MinIO/S3 via OpenDAL)
    pub storage: Operator,
    
}

impl AppState {
    /// Create new AppState with dependency injection
    ///
    /// # Example
    /// ```no_run
    /// use redis::Client;
    /// use example_app_with_s3::state::AppState;
    ///
    /// #[tokio::main]
    /// async fn main() -> Result<(), Box<dyn std::error::Error>> {
    ///     let client = Client::open("redis://localhost:6379")?;
    ///     let conn = client.get_multiplexed_async_connection().await?;
    ///     let state = AppState::new(conn, storage);
    ///     Ok(())
    /// }
    /// ```
    pub fn new(
        redis: MultiplexedConnection,
        
        storage: Operator,
        
    ) -> Self {
        Self {
            redis,
            
            storage,
            
        }
    }
}
