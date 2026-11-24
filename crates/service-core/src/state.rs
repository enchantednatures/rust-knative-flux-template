use metrics_exporter_prometheus::PrometheusHandle;
#[cfg(feature = "s3")]
use opendal::Operator;
use redis::aio::MultiplexedConnection;
#[cfg(any(feature = "kafka", feature = "postgres"))]
use std::sync::Arc;

#[cfg(feature = "kafka")]
use crate::kafka::KafkaPublisher;

/// Application state shared across all handlers
/// Uses dependency injection pattern - accepts pre-configured dependencies
#[derive(Clone)]
pub struct AppState {
    /// Redis multiplexed connection - supports Clone and handles concurrency internally
    /// No need for Arc<RwLock<>> - MultiplexedConnection is already designed for this
    pub redis: MultiplexedConnection,
    #[cfg(feature = "s3")]
    /// S3-compatible storage operator (RustFS/S3 via OpenDAL)
    pub storage: Operator,
    #[cfg(feature = "kafka")]
    /// Kafka publisher for event publishing
    pub kafka_publisher: Option<Arc<KafkaPublisher>>,
    #[cfg(feature = "postgres")]
    /// PostgreSQL connection pool (sqlx PgPool)
    pub postgres: Option<Arc<sqlx::PgPool>>,
    /// Prometheus metrics handle for /metrics endpoint
    pub metrics_handle: PrometheusHandle,
}

/// Feature-stable builder for [`AppState`].
///
/// Unlike [`AppState::new`], whose parameter list follows this crate's feature
/// flags, the builder keeps the same call shape in every feature combination.
/// Generated test helpers use it so a workspace-wide `--all-features` build
/// compiles an app whose own feature set omits some service-core features.
pub struct AppStateBuilder {
    redis: MultiplexedConnection,
    #[cfg(feature = "s3")]
    storage: Option<Operator>,
    #[cfg(feature = "kafka")]
    kafka_publisher: Option<Arc<KafkaPublisher>>,
    #[cfg(feature = "postgres")]
    postgres: Option<sqlx::PgPool>,
    metrics_handle: PrometheusHandle,
}

impl AppStateBuilder {
    /// Attach a storage operator (the `s3` feature).
    #[cfg(feature = "s3")]
    pub fn storage(mut self, storage: Operator) -> Self {
        self.storage = Some(storage);
        self
    }

    /// Attach an optional Kafka publisher (the `kafka` feature).
    #[cfg(feature = "kafka")]
    pub fn kafka_publisher(mut self, publisher: Option<Arc<KafkaPublisher>>) -> Self {
        self.kafka_publisher = publisher;
        self
    }

    /// Attach an optional PostgreSQL pool (the `postgres` feature).
    #[cfg(feature = "postgres")]
    pub fn postgres(mut self, pool: Option<sqlx::PgPool>) -> Self {
        self.postgres = pool;
        self
    }

    /// Finish the state. When `s3` is enabled but no operator was supplied,
    /// an in-memory operator keeps feature-unified builds usable.
    pub fn build(self) -> anyhow::Result<AppState> {
        #[cfg(feature = "s3")]
        let storage = match self.storage {
            Some(storage) => storage,
            None => Operator::new(opendal::services::Memory::default())?.finish(),
        };

        Ok(AppState {
            redis: self.redis,
            #[cfg(feature = "s3")]
            storage,
            #[cfg(feature = "kafka")]
            kafka_publisher: self.kafka_publisher,
            #[cfg(feature = "postgres")]
            postgres: self.postgres.map(Arc::new),
            metrics_handle: self.metrics_handle,
        })
    }
}

impl AppState {
    /// Start a feature-stable [`AppStateBuilder`].
    pub fn builder(
        redis: MultiplexedConnection,
        metrics_handle: PrometheusHandle,
    ) -> AppStateBuilder {
        AppStateBuilder {
            redis,
            #[cfg(feature = "s3")]
            storage: None,
            #[cfg(feature = "kafka")]
            kafka_publisher: None,
            #[cfg(feature = "postgres")]
            postgres: None,
            metrics_handle,
        }
    }

    /// Create new AppState with dependency injection.
    ///
    /// The parameter list grows only with the crate features that are enabled:
    /// `s3` adds the storage operator, `kafka` the optional publisher, and
    /// `postgres` the optional pool.
    ///
    /// # Example
    /// ```ignore
    /// use redis::Client;
    /// use service_core::state::AppState;
    ///
    /// #[tokio::main]
    /// async fn main() -> Result<(), Box<dyn std::error::Error>> {
    ///     let client = Client::open("redis://localhost:6379")?;
    ///     let conn = client.get_multiplexed_async_connection().await?;
    ///     let metrics_handle = service_core::observability::init_metrics("my-service")?;
    ///     let state = AppState::new(conn, metrics_handle);
    ///     Ok(())
    /// }
    /// ```
    pub fn new(
        redis: MultiplexedConnection,
        #[cfg(feature = "s3")] storage: Operator,
        #[cfg(feature = "kafka")] kafka_publisher: Option<Arc<KafkaPublisher>>,
        #[cfg(feature = "postgres")] pool: Option<sqlx::PgPool>,
        metrics_handle: PrometheusHandle,
    ) -> Self {
        Self {
            redis,
            #[cfg(feature = "s3")]
            storage,
            #[cfg(feature = "kafka")]
            kafka_publisher,
            #[cfg(feature = "postgres")]
            postgres: pool.map(Arc::new),
            metrics_handle,
        }
    }
}
