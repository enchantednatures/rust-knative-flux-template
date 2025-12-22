use example_app_no_s3::{config::Config, observability, routes, state::AppState};
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
    // 2. Initialize Observability (Tracing + OpenTelemetry)
    // =========================================================================
    observability::init_telemetry(&config.telemetry)?;
    tracing::info!(
        service_name = %config.telemetry.service_name,
        otlp_endpoint = ?config.telemetry.otlp_endpoint,
        "Telemetry initialized"
    );

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
    // 4. Create Application State (Dependency Injection)
    // =========================================================================
    let state = AppState::new(redis_conn);

    // =========================================================================
    // 5. Setup HTTP Server with Axum
    // =========================================================================
    let app = routes::create_router(state);

    // =========================================================================
    // 6. Start Server with Graceful Shutdown
    // =========================================================================
    let listener = tokio::net::TcpListener::bind(format!("{}:{}", config.server.host, config.server.port))
        .await
        .map_err(|e| {
            tracing::error!(error = %e, "Failed to bind to address");
            e
        })?;

    tracing::info!(
        address = %listener.local_addr()?,
        "Server starting"
    );

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .map_err(|e| {
            tracing::error!(error = %e, "Server error");
            e
        })?;

    tracing::info!("Server shutdown complete");
    Ok(())
}

/// Graceful shutdown signal handler
///
/// Listens for Ctrl+C (SIGINT) and SIGTERM signals
/// and returns when either is received.
async fn shutdown_signal() {
    let ctrl_c = async {
        signal::ctrl_c()
            .await
            .expect("failed to install Ctrl+C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("failed to install signal handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {
            tracing::info!("shutdown signal received: Ctrl+C");
        },
        _ = terminate => {
            tracing::info!("shutdown signal received: SIGTERM");
        },
    }

    tracing::info!("shutdown signal received, starting graceful shutdown");
}