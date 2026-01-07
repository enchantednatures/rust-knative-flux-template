use test_app_no_s3::{config::Config, observability, routes, state::AppState};
use tokio::signal;

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

    // =========================================================================
    // 4. Build Application State
    // =========================================================================
    let state = AppState::new(redis_conn, metrics_handle);

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

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    // =========================================================================
    // 7. Graceful Shutdown
    // =========================================================================
    tracing::info!("Server shutting down");
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
