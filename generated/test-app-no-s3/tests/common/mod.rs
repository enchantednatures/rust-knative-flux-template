use test_app_no_s3::state::AppState;

/// Create a test AppState with a mock Redis connection
/// For integration tests, use a real Redis instance (e.g., via docker-compose or testcontainers)
pub async fn create_test_state() -> AppState {
    let redis_url =
        std::env::var("APP__REDIS__URL").unwrap_or_else(|_| "redis://localhost:6379".to_string());

    let client = redis::Client::open(redis_url).expect("Failed to create Redis client");
    let conn = client
        .get_multiplexed_async_connection()
        .await
        .expect("Failed to connect to Redis");

    // Create a mock metrics handle for testing
    let metrics_handle = metrics_exporter_prometheus::PrometheusBuilder::new()
        .install_recorder()
        .expect("Failed to install metrics recorder");
    AppState::new(conn, metrics_handle)
}
