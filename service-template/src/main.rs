use {{ crate_name }}::{bootstrap, config::Config, routes};

use tokio::signal;

{%- if include_postgres %}

/// Embedded SQL migrations compiled from `./migrations` at build time.
/// `Migrator::run` takes a PostgreSQL advisory lock, so concurrently starting
/// replicas serialize safely.
static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!();
{%- endif %}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Fail fast: load and validate configuration before touching dependencies.
    let config = Config::load().map_err(|e| {
        eprintln!("Configuration error: {}", e);
        e
    })?;

    // Telemetry + metrics, Redis, the optional S3/Kafka/PostgreSQL
    // initializers, and `AppState` are all owned by service-core.
    let runtime = bootstrap::initialize(&config, env!("CARGO_PKG_NAME"){%- if include_postgres %}, Some(&MIGRATOR){%- else %}, None{%- endif %}).await?;

    let app = routes::create_router(runtime.state.clone());

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

    tracing::info!("Server shutting down");
    // Closes the PostgreSQL pool (when configured) and flushes telemetry.
    runtime.shutdown().await;

    Ok(())
}

/// Wait for SIGTERM or SIGINT.
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
