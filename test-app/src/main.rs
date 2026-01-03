use axum::{
    extract::State,
    http::StatusCode,
    response::IntoResponse,
    routing::get,
    Json, Router,
};
use serde::{Deserialize, Serialize};
use sqlx::postgres::{PgPoolOptions, PgConnectOptions};
use sqlx::{ConnectOptions, Pool, Postgres};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use tracing::{error, info};

#[derive(Clone)]
struct AppState {
    db: Arc<Pool<Postgres>>,
}

#[derive(Debug, Serialize, Deserialize)]
struct Task {
    id: i32,
    title: String,
    completed: bool,
}

#[derive(Debug, Serialize)]
struct HealthResponse {
    status: String,
    database: String,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::INFO)
        .init();

    let database_url = std::env::var("DATABASE_URL")
        .unwrap_or_else(|_| "postgresql://app:MULcae3rkwVldPKbgZaR8Pitwge3w99wL4CwlyeFkHZkLk3iCv8iBSHtg8YfLX3x@localhost:5432/app".to_string());

    let ssl_mode = std::env::var("SSL_MODE")
        .unwrap_or_else(|_| "require".to_string());

    info!("Starting PostgreSQL test application");
    info!("SSL Mode: {}", &ssl_mode);
    info!("Connecting to database...");
    
    let connect_options = PgConnectOptions::new()
        .host("localhost")
        .port(5432)
        .database("app")
        .username("app")
        .password("MULcae3rkwVldPKbgZaR8Pitwge3w99wL4CwlyeFkHZkLk3iCv8iBSHtg8YfLX3x")
        .ssl_mode(match ssl_mode.as_str() {
            "disable" => sqlx::postgres::PgSslMode::Disable,
            "allow" => sqlx::postgres::PgSslMode::Allow,
            "prefer" => sqlx::postgres::PgSslMode::Prefer,
            "require" => sqlx::postgres::PgSslMode::Require,
            "verify-full" => sqlx::postgres::PgSslMode::VerifyFull,
            _ => sqlx::postgres::PgSslMode::Prefer,
        });
    
    let pool = match PgPoolOptions::new()
        .max_connections(5)
        .acquire_timeout(Duration::from_secs(5))
        .connect_with(connect_options)
        .await
    {
        Ok(pool) => {
            info!("✓ Connected to database");
            pool
        }
        Err(e) => {
            error!("Failed to connect to database: {}", e);
            std::process::exit(1);
        }
    };

    info!("Running migrations...");
    if let Err(e) = sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS tasks (
            id SERIAL PRIMARY KEY,
            title TEXT NOT NULL,
            completed BOOLEAN NOT NULL DEFAULT false,
            created_at TIMESTAMP NOT NULL DEFAULT NOW()
        )
        "#,
    )
    .execute(&pool)
    .await
    {
        error!("Failed to run migrations: {}", e);
        std::process::exit(1);
    }

    info!("✓ Database ready");

    let state = AppState {
        db: Arc::new(pool),
    };

    let app = Router::new()
        .route("/health", get(health_check))
        .route("/tasks", get(list_tasks))
        .with_state(state);

    let addr = SocketAddr::from(([127, 0, 0, 1], 3000));
    info!("Server listening on {}", addr);
    
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("Failed to bind to port 3000");
    
    axum::serve(listener, app)
        .await
        .expect("Server error");
}

async fn health_check(State(state): State<AppState>) -> impl IntoResponse {
    match sqlx::query("SELECT 1").fetch_one(state.db.as_ref()).await {
        Ok(_) => {
            let response = HealthResponse {
                status: "healthy".to_string(),
                database: "connected".to_string(),
            };
            (StatusCode::OK, Json(response)).into_response()
        }
        Err(e) => {
            error!("Database health check failed: {}", e);
            let response = HealthResponse {
                status: "unhealthy".to_string(),
                database: format!("error: {}", e),
            };
            (StatusCode::SERVICE_UNAVAILABLE, Json(response)).into_response()
        }
    }
}

async fn list_tasks(State(state): State<AppState>) -> Json<Vec<Task>> {
    match sqlx::query_as::<_, (i32, String, bool)>(
        "SELECT id, title, completed FROM tasks ORDER BY created_at DESC"
    )
    .fetch_all(state.db.as_ref())
    .await
    {
        Ok(rows) => {
            let tasks: Vec<Task> = rows
                .into_iter()
                .map(|(id, title, completed)| Task { id, title, completed })
                .collect();
            info!("Listed {} tasks", tasks.len());
            Json(tasks)
        }
        Err(e) => {
            error!("Failed to list tasks: {}", e);
            Json(vec![])
        }
    }
}
