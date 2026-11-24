//! Startup orchestration shared by generated services.
//!
//! The application entry point loads and validates [`Config`], calls
//! [`initialize`], serves the HTTP router with the returned [`Runtime::state`],
//! and calls [`Runtime::shutdown`] after the server stops. Every dependency is
//! initialized in the same order the template always used (telemetry, metrics,
//! Redis, then optional S3/Kafka/PostgreSQL) and every failure remains
//! fail-fast.

use opentelemetry_sdk::trace::SdkTracerProvider;
use redis::aio::MultiplexedConnection;

use crate::config::{Config, RedisConfig, TelemetryConfig};
use crate::observability;
use crate::state::AppState;

#[cfg(feature = "kafka")]
use crate::config::KafkaConfig;
#[cfg(feature = "kafka")]
use crate::kafka::KafkaPublisher;
#[cfg(feature = "kafka")]
use std::sync::Arc;

#[cfg(feature = "postgres")]
use crate::config::PostgresConfig;
#[cfg(feature = "postgres")]
use sqlx::migrate::Migrator;
#[cfg(feature = "postgres")]
use sqlx::postgres::{PgConnectOptions, PgSslMode};
#[cfg(feature = "postgres")]
use std::time::Duration;

/// Placeholder used by generated projects without PostgreSQL migrations.
///
/// The bootstrap signature keeps the migration argument in both feature
/// states so a workspace-wide `--all-features` build compiles an app whose own
/// feature set omits `postgres` (feature unification can still enable it on
/// this crate).
#[cfg(not(feature = "postgres"))]
#[derive(Debug)]
pub struct Migrator;

#[cfg(feature = "s3")]
use crate::config::S3Config;

/// Fully initialized application runtime.
///
/// Holds the shared state handed to the router plus the resources that need an
/// explicit shutdown (the PostgreSQL pool and the OpenTelemetry tracer
/// provider).
pub struct Runtime {
    /// Shared state for the HTTP router.
    pub state: AppState,
    tracer_provider: Option<SdkTracerProvider>,
    #[cfg(feature = "postgres")]
    postgres_pool: Option<sqlx::PgPool>,
}

impl Runtime {
    /// Close the PostgreSQL pool (when configured) and flush telemetry.
    ///
    /// Mirrors the template's historical shutdown order: the pool is closed
    /// first so pending acquires fail immediately and idle connections are
    /// dropped, then the tracer provider is shut down.
    pub async fn shutdown(self) {
        #[cfg(feature = "postgres")]
        {
            if let Some(pool) = self.postgres_pool {
                tracing::debug!("Closing PostgreSQL connection pool");
                pool.close().await;
            }
        }
        observability::shutdown_telemetry(self.tracer_provider);
    }
}

/// Initialize the tracing subscriber and (optionally) the OTLP exporter.
pub fn init_telemetry(config: &TelemetryConfig) -> anyhow::Result<Option<SdkTracerProvider>> {
    let tracer_provider = observability::init_telemetry(config)?;
    tracing::info!(
        service_name = %config.service_name,
        otlp_endpoint = ?config.otlp_endpoint,
        "Telemetry initialized"
    );
    Ok(tracer_provider)
}

/// Install the Prometheus recorder and return the handle used by `/metrics`.
pub fn init_metrics(
    service_name: &str,
) -> anyhow::Result<metrics_exporter_prometheus::PrometheusHandle> {
    let handle = observability::init_metrics(service_name)?;
    tracing::info!("Metrics initialized (Prometheus available at GET /metrics)");
    Ok(handle)
}

/// Connect to Redis (required by every service).
pub async fn init_redis(config: &RedisConfig) -> anyhow::Result<MultiplexedConnection> {
    tracing::info!(redis_url = %config.url, "Connecting to Redis");
    let redis_client = redis::Client::open(config.url.as_str())?;
    let redis_conn = redis_client
        .get_multiplexed_async_connection()
        .await
        .map_err(|e| {
            tracing::error!(error = %e, "Failed to connect to Redis");
            anyhow::Error::new(e)
        })?;
    tracing::info!("Redis connection established");
    Ok(redis_conn)
}

/// Initialize the S3-compatible storage operator (OpenDAL).
#[cfg(feature = "s3")]
pub fn init_s3(config: &S3Config) -> anyhow::Result<opendal::Operator> {
    tracing::info!(
        endpoint = %config.endpoint,
        bucket = %config.bucket,
        "Initializing S3-compatible storage"
    );
    let builder = opendal::services::S3::default()
        .endpoint(&config.endpoint)
        .bucket(&config.bucket)
        .region(&config.region);

    let storage = opendal::Operator::new(builder)?.finish();
    tracing::info!("S3-compatible storage initialized");
    Ok(storage)
}

/// Initialize the Kafka publisher when event publishing is configured.
#[cfg(feature = "kafka")]
pub async fn init_kafka(
    config: Option<KafkaConfig>,
) -> anyhow::Result<Option<Arc<KafkaPublisher>>> {
    let Some(kafka_config) = config else {
        tracing::info!("Kafka publishing not configured");
        return Ok(None);
    };

    tracing::info!(
        broker_url = %kafka_config.broker_url,
        topic = %kafka_config.topic,
        "Initializing Kafka publisher"
    );

    match KafkaPublisher::new(kafka_config).await {
        Ok(publisher) => {
            tracing::info!("Kafka publisher initialized");
            Ok(Some(Arc::new(publisher)))
        }
        Err(e) => {
            tracing::error!(error = %e, "Failed to initialize Kafka publisher - exiting (fail fast)");
            Err(anyhow::anyhow!(
                "Kafka publisher initialization failed: {}",
                e
            ))
        }
    }
}

/// Build PostgreSQL connect options from the configured DSN.
///
/// Applies the optional host override (`APP__POSTGRES__HOST`, used for the
/// PgBouncer Pooler) and the optional database override
/// (`APP__POSTGRES__DATABASE`, used by services that own a database on the
/// shared cluster). Overrides are applied after parsing, so credentials,
/// port, and TLS-relevant DSN parameters are preserved.
#[cfg(feature = "postgres")]
pub fn pg_connect_options(config: &PostgresConfig) -> anyhow::Result<PgConnectOptions> {
    let mut opts = config.url.parse::<PgConnectOptions>()?;

    if let Some(pg_host) = &config.host {
        opts = opts.host(pg_host);
    }

    if let Some(database) = config.database.as_deref().filter(|db| !db.is_empty()) {
        opts = opts.database(database);
    }

    let ssl_mode = match config.ssl_mode.as_str() {
        "disable" => PgSslMode::Disable,
        "require" => PgSslMode::Require,
        "verify-ca" => PgSslMode::VerifyCa,
        "verify-full" => PgSslMode::VerifyFull,
        other => anyhow::bail!("Invalid postgres.ssl_mode: {}", other),
    };

    Ok(opts.ssl_mode(ssl_mode))
}

/// Initialize the lazy PostgreSQL pool and run embedded migrations.
///
/// An empty URL means "no database configured": the pool stays `None` and
/// `/health/ready` reports not-ready instead of failing at startup.
#[cfg(feature = "postgres")]
pub async fn init_postgres(
    config: &PostgresConfig,
    migrator: Option<&Migrator>,
) -> anyhow::Result<Option<sqlx::PgPool>> {
    if config.url.is_empty() {
        tracing::info!("PostgreSQL URL not configured - connection pool disabled");
        return Ok(None);
    }

    let mut opts = pg_connect_options(config).map_err(|e| {
        tracing::error!(error = %e, "Failed to parse PostgreSQL DSN - exiting (fail fast)");
        anyhow::anyhow!("PostgreSQL DSN parse failed: {}", e)
    })?;

    if let Some(cert_path) = &config.ssl_root_cert_path {
        let pem = tokio::fs::read(cert_path).await.map_err(|e| {
            tracing::error!(error = %e, path = %cert_path, "Failed to read PostgreSQL SSL root certificate - exiting (fail fast)");
            anyhow::anyhow!(
                "Failed to read PostgreSQL SSL root certificate at {}: {}",
                cert_path,
                e
            )
        })?;
        // Trust-store diagnostics: proves the root actually reached the
        // verifier. If a failed handshake shows UnknownIssuer while an
        // independent pod verifies fine with the same CA, these fields
        // tell us whether the app consumed the wrong bytes (or none).
        tracing::info!(
            path = %cert_path,
            ssl_mode = %config.ssl_mode,
            pem_bytes = pem.len(),
            pem_header = %String::from_utf8_lossy(
                pem.get(..16).unwrap_or(b" ")
            ).trim_end(),
            "PostgreSQL CA loaded from mounted secret"
        );
        opts = opts.ssl_root_cert_from_pem(pem);
    } else {
        tracing::info!(
            ssl_mode = %config.ssl_mode,
            "No postgres.ssl_root_cert_path configured - relying on system/webpki root store"
        );
    }

    // Lazy pool: no connection is attempted until the first acquire, so
    // startup stays fast and cold-start latency is unaffected.
    let pool = sqlx::postgres::PgPoolOptions::new()
        .max_connections(config.max_connections)
        .min_connections(0)
        .acquire_timeout(Duration::from_secs(5))
        .idle_timeout(Duration::from_secs(300))
        .max_lifetime(Duration::from_secs(1800))
        .connect_lazy_with(opts);

    if config.run_migrations {
        match migrator {
            Some(migrator) => {
                tracing::info!("Running PostgreSQL startup migrations");
                migrator.run(&pool).await.map_err(|e| {
                    tracing::error!(error = %e, "PostgreSQL startup migrations failed - exiting (fail fast)");
                    anyhow::anyhow!("PostgreSQL startup migrations failed: {}", e)
                })?;
                tracing::info!("PostgreSQL startup migrations applied");
            }
            None => {
                tracing::debug!("No migrator provided - skipping PostgreSQL startup migrations");
            }
        }
    }

    tracing::info!(
        max_connections = config.max_connections,
        ssl_mode = %config.ssl_mode,
        "PostgreSQL connection pool initialized (lazy)"
    );
    Ok(Some(pool))
}

/// Initialize every dependency in startup order and build the shared state.
///
/// `service_name` is the application package name (`env!("CARGO_PKG_NAME")`
/// in the service binary); it is used as the global Prometheus `service`
/// label. The optional migrator stays owned by the service crate because it
/// embeds that service's migrations; services without PostgreSQL pass `None`.
pub async fn initialize(
    config: &Config,
    service_name: &str,
    _migrator: Option<&Migrator>,
) -> anyhow::Result<Runtime> {
    let tracer_provider = init_telemetry(&config.telemetry)?;
    let metrics_handle = init_metrics(service_name)?;

    let redis = init_redis(&config.redis).await?;

    #[cfg(feature = "s3")]
    let storage = init_s3(&config.s3)?;

    #[cfg(feature = "kafka")]
    let kafka_publisher = init_kafka(config.kafka.clone()).await?;

    #[cfg(feature = "postgres")]
    let postgres_pool = init_postgres(&config.postgres, _migrator).await?;

    let state = AppState::new(
        redis,
        #[cfg(feature = "s3")]
        storage,
        #[cfg(feature = "kafka")]
        kafka_publisher,
        #[cfg(feature = "postgres")]
        postgres_pool.clone(),
        metrics_handle,
    );

    Ok(Runtime {
        state,
        tracer_provider,
        #[cfg(feature = "postgres")]
        postgres_pool,
    })
}

#[cfg(test)]
mod tests {
    #[cfg(feature = "postgres")]
    use super::pg_connect_options;
    #[cfg(feature = "postgres")]
    use crate::config::Config;
    #[cfg(feature = "postgres")]
    use figment::{
        Figment,
        providers::{Env, Serialized},
    };

    /// `APP__POSTGRES__DATABASE` must replace the DSN database while keeping
    /// host, port, and credentials from the operator-generated `uri`.
    #[cfg(feature = "postgres")]
    #[test]
    #[allow(clippy::result_large_err)]
    fn test_database_override_preserves_connection_fields() {
        figment::Jail::expect_with(|jail| {
            jail.set_env(
                "APP__POSTGRES__URL",
                "postgres://user:pass@host:5432/app?sslmode=require",
            );
            jail.set_env("APP__POSTGRES__DATABASE", "svc_db");

            let config: Config = Figment::new()
                .merge(Serialized::defaults(Config::default()))
                .merge(Env::prefixed("APP__").split("__"))
                .extract()?;

            let opts = pg_connect_options(&config.postgres)
                .map_err(|e| figment::Error::from(e.to_string()))?;
            assert_eq!(opts.get_database(), Some("svc_db"));
            assert_eq!(opts.get_host(), "host");
            assert_eq!(opts.get_port(), 5432);
            assert_eq!(opts.get_username(), "user");
            Ok(())
        });
    }
}
