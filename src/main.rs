use {{ crate_name }}::{config::Config, observability, routes, state::AppState};
{%- if feature_kafka %}
use std::sync::Arc;
{%- endif %}
{%- if feature_postgres %}
use std::time::Duration;
{%- endif %}
use tokio::signal;

{%- if feature_postgres %}
/// Embedded SQL migrations compiled from ./migrations at build time.
/// `Migrator::run` acquires a PostgreSQL advisory lock before applying
/// migrations, so concurrently starting replicas serialize safely.
static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!();
{%- endif %}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // =========================================================================
    // 1. Early Environment Validation - Fail Fast
    // =========================================================================
    // Load and validate configuration before initializing anything else
    // This ensures we fail immediately if required env vars are missing
    let config = Config::load().map_err(|e| {
        eprintln!("Configuration error: {}", e);
        e
    })?;

    // =========================================================================
    // 2. Initialize Observability (Tracing + OpenTelemetry + Metrics)
    // =========================================================================
    // Store the tracer provider for explicit shutdown (OpenTelemetry 0.31+)
    let tracer_provider = observability::init_telemetry(&config.telemetry)?;
    tracing::info!(
        service_name = %config.telemetry.service_name,
        otlp_endpoint = ?config.telemetry.otlp_endpoint,
        "Telemetry initialized"
    );

    // Initialize Prometheus metrics and get handle for /metrics endpoint
    let metrics_handle = observability::init_metrics()?;
    tracing::info!("Metrics initialized (Prometheus available at GET /metrics)");

    // =========================================================================
    // 3. Initialize Redis Connection (Dependency Injection)
    // =========================================================================
    tracing::info!(redis_url = %config.redis.url, "Connecting to Redis");
    let redis_client = redis::Client::open(config.redis.url.as_str())?;
    let redis_conn = redis_client
        .get_multiplexed_async_connection()
        .await
        .map_err(|e| {
            tracing::error!(error = %e, "Failed to connect to Redis");
            e
        })?;
    tracing::info!("Redis connection established");
    {%- if feature_s3 %}
    // =========================================================================
    // 3b. Initialize S3-compatible Storage (OpenDAL)
    // =========================================================================
    tracing::info!(
        endpoint = %config.s3.endpoint,
        bucket = %config.s3.bucket,
        "Initializing S3-compatible storage"
    );
    let storage = {
        let builder = opendal::services::S3::default()
            .endpoint(&config.s3.endpoint)
            .bucket(&config.s3.bucket)
            .region(&config.s3.region);

        opendal::Operator::new(builder)?.finish()
    };
    tracing::info!("S3-compatible storage initialized");
    {%- endif %}
    {%- if feature_kafka %}

    // =========================================================================
    // 3c. Initialize Kafka Publisher (Event Publishing)
    // =========================================================================
    use {{ crate_name }}::handlers::kafka::KafkaPublisher;
    let kafka_publisher = if let Some(kafka_config) = config.kafka.clone() {
        tracing::info!(
            broker_url = %kafka_config.broker_url,
            topic = %kafka_config.topic,
            "Initializing Kafka publisher"
        );

        match KafkaPublisher::new(kafka_config).await {
            Ok(publisher) => {
                tracing::info!("Kafka publisher initialized");
                Some(Arc::new(publisher))
            }
            Err(e) => {
                tracing::error!(error = %e, "Failed to initialize Kafka publisher - exiting (fail fast)");
                return Err(anyhow::anyhow!(
                    "Kafka publisher initialization failed: {}",
                    e
                ));
            }
        }
    } else {
        tracing::info!("Kafka publishing not configured");
        None
    };
    {%- endif %}
    {%- if feature_postgres %}

    // =========================================================================
    // 3d. Initialize PostgreSQL (lazy pool + optional startup migrations)
    // =========================================================================
    // Empty URL means "no database configured": skip pool creation and let
    // /health/ready report not-ready instead of failing at startup.
    let pg_pool_raw: Option<sqlx::PgPool> = if config.postgres.url.is_empty() {
        tracing::info!("PostgreSQL URL not configured - connection pool disabled");
        None
    } else {
        let mut opts = config
            .postgres
            .url
            .parse::<sqlx::postgres::PgConnectOptions>()
            .map_err(|e| {
                tracing::error!(error = %e, "Failed to parse PostgreSQL DSN - exiting (fail fast)");
                anyhow::anyhow!("PostgreSQL DSN parse failed: {}", e)
            })?;

        // Host override: when a PgBouncer Pooler fronts the cluster, the
        // operator's generated `uri` secret still points at <cluster>-rw --
        // rewrite the host so the pool connects through the pooler while
        // keeping credentials and dbname from the same secret.
        if let Some(pg_host) = &config.postgres.host {
            opts = opts.host(pg_host);
        }

        opts = opts.ssl_mode(match config.postgres.ssl_mode.as_str() {
            "disable" => sqlx::postgres::PgSslMode::Disable,
            "require" => sqlx::postgres::PgSslMode::Require,
            "verify-ca" => sqlx::postgres::PgSslMode::VerifyCa,
            "verify-full" => sqlx::postgres::PgSslMode::VerifyFull,
            other => {
                tracing::error!(ssl_mode = %other, "Invalid postgres.ssl_mode - exiting (fail fast)");
                return Err(anyhow::anyhow!("Invalid postgres.ssl_mode: {}", other));
            }
        });

        if let Some(cert_path) = &config.postgres.ssl_root_cert_path {
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
                ssl_mode = %config.postgres.ssl_mode,
                pem_bytes = pem.len(),
                pem_header = %String::from_utf8_lossy(
                    pem.get(..16).unwrap_or(b" ")
                ).trim_end(),
                "PostgreSQL CA loaded from mounted secret"
            );
            opts = opts.ssl_root_cert_from_pem(pem);
        } else {
            tracing::info!(
                ssl_mode = %config.postgres.ssl_mode,
                "No postgres.ssl_root_cert_path configured - relying on system/webpki root store"
            );
        }

        // Lazy pool: no connection is attempted until the first acquire, so
        // startup stays fast and cold-start latency is unaffected.
        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(config.postgres.max_connections)
            .min_connections(0)
            .acquire_timeout(Duration::from_secs(5))
            .idle_timeout(Duration::from_secs(300))
            .max_lifetime(Duration::from_secs(1800))
            .connect_lazy_with(opts);

        if config.postgres.run_migrations {
            tracing::info!("Running PostgreSQL startup migrations");
            MIGRATOR.run(&pool).await.map_err(|e| {
                tracing::error!(error = %e, "PostgreSQL startup migrations failed - exiting (fail fast)");
                anyhow::anyhow!("PostgreSQL startup migrations failed: {}", e)
            })?;
            tracing::info!("PostgreSQL startup migrations applied");
        }

        tracing::info!(
            max_connections = config.postgres.max_connections,
            ssl_mode = %config.postgres.ssl_mode,
            "PostgreSQL connection pool initialized (lazy)"
        );
        Some(pool)
    };
    // PgPool::clone shares the underlying Arc (cheap); pg_pool_raw is kept
    // for the graceful close in section 7.
    let postgres_pool = pg_pool_raw.clone();
    {%- endif %}

    // =========================================================================
    // 4. Build Application State
    // =========================================================================
    {%- if feature_s3 %}
    {%- if feature_kafka %}
    let state = AppState::new(
        redis_conn,
        storage,
        kafka_publisher,
        {%- if feature_postgres %}
        postgres_pool,
        {%- endif %}
        metrics_handle,
    );
    {%- else %}
    let state = AppState::new(
        redis_conn,
        storage,
        {%- if feature_postgres %}
        postgres_pool,
        {%- endif %}
        metrics_handle,
    );
    {%- endif %}
    {%- else %}
    {%- if feature_kafka %}
    let state = AppState::new(
        redis_conn,
        kafka_publisher,
        {%- if feature_postgres %}
        postgres_pool,
        {%- endif %}
        metrics_handle,
    );
    {%- else %}
    let state = AppState::new(
        redis_conn,
        {%- if feature_postgres %}
        postgres_pool,
        {%- endif %}
        metrics_handle,
    );
    {%- endif %}
    {%- endif %}

    // =========================================================================
    // 5. Create Router
    // =========================================================================
    let app = routes::create_router(state);

    // =========================================================================
    // 6. Start HTTP Server
    // =========================================================================
    let addr = format!("{}:{}", config.server.host, config.server.port);
    tracing::info!(address = %addr, "Starting server");

    let listener = tokio::net::TcpListener::bind(&addr).await?;
    tracing::info!("Server listening on {}", addr);

    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
    )
    .with_graceful_shutdown(shutdown_signal())
    .await?;

    // =========================================================================
    // 7. Graceful Shutdown
    // =========================================================================
    tracing::info!("Server shutting down");
    {%- if feature_postgres %}
    // Close the PostgreSQL pool: pending acquires fail immediately and idle
    // connections are dropped; in-flight connections close as they are
    // returned. With CNPG the server side also terminates connections when the
    // pod exits, but closing here gives clean protocol-level disconnects
    // during rolling updates.
    if let Some(pool) = pg_pool_raw {
        tracing::debug!("Closing PostgreSQL connection pool");
        pool.close().await;
    }
    {%- endif %}
    observability::shutdown_telemetry(tracer_provider);

    Ok(())
}

/// Wait for shutdown signal (SIGTERM or SIGINT)
async fn shutdown_signal() {
    let ctrl_c = async {
        signal::ctrl_c()
            .await
            .expect("Failed to install Ctrl+C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("Failed to install SIGTERM handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {
            tracing::info!("Received Ctrl+C signal");
        },
        _ = terminate => {
            tracing::info!("Received SIGTERM signal");
        },
    }
}
