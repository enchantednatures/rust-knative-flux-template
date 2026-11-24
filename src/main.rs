use {{ crate_name }}::{bootstrap, config::Config, routes};
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
    // 2-4. Observability, Dependencies, and Application State
    // =========================================================================
    // Shared startup lives in service-core: telemetry + metrics, Redis, then
    // the optional S3/Kafka/PostgreSQL initializers, followed by AppState.
    // Every failure is fail-fast, preserving the historical startup order.
    let runtime = bootstrap::initialize(
        &config,
        env!("CARGO_PKG_NAME"),
        {%- if feature_postgres %}
        Some(&MIGRATOR),
        {%- else %}
        None,
        {%- endif %}
    )
    .await?;

    // =========================================================================
    // 5. Create Router
    // =========================================================================
    let app = routes::create_router(runtime.state.clone());

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
    // Closes the PostgreSQL pool (when configured) and flushes telemetry.
    runtime.shutdown().await;

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
