use std::net::SocketAddr;
use std::sync::OnceLock;

use axum::body::Body;
use axum::extract::ConnectInfo;
use axum::http::Request;
use axum::middleware::Next;
use axum::response::Response;
use axum_test::TestServer;

use {{ crate_name }}::observability;
use {{ crate_name }}::state::AppState;

use metrics_exporter_prometheus::PrometheusHandle;
{%- if feature_s3 %}

use opendal::Operator;
{%- endif %}

/// The global metrics recorder can only be installed once per process, but
/// every test calls `create_test_state`. Share the first installed handle.
static METRICS_HANDLE: OnceLock<PrometheusHandle> = OnceLock::new();

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

    // Initialize metrics properly (same as production) to ensure tests match runtime behavior
    let metrics_handle = METRICS_HANDLE
        .get_or_init(|| observability::init_metrics().expect("Failed to initialize metrics"))
        .clone();

{%- if feature_s3 and feature_kafka %}
    let storage = create_test_storage();
    AppState::new(conn, storage, None{%- if feature_postgres %}, None{%- endif %}, metrics_handle)
{%- elsif feature_s3 %}
    let storage = create_test_storage();
    AppState::new(conn, storage{%- if feature_postgres %}, None{%- endif %}, metrics_handle)
{%- elsif feature_kafka %}
    AppState::new(conn, None{%- if feature_postgres %}, None{%- endif %}, metrics_handle)
{%- else %}
    AppState::new(conn{%- if feature_postgres %}, None{%- endif %}, metrics_handle)
{%- endif %}
}

/// Build a `TestServer` for the app router with a synthetic peer address.
///
/// The rate limiter (`tower_governor`) reads the client IP from the
/// `ConnectInfo` request extension that `axum::serve` inserts at runtime;
/// `axum-test`'s mocked transport does not, so inject a loopback address.
pub fn create_test_server(state: AppState) -> TestServer {
    let app = {{ crate_name }}::routes::create_router(state)
        .layer(axum::middleware::from_fn(inject_connect_info));
    TestServer::new(app).expect("Failed to create test server")
}

async fn inject_connect_info(mut request: Request<Body>, next: Next) -> Response {
    request
        .extensions_mut()
        .insert(ConnectInfo(SocketAddr::from(([127, 0, 0, 1], 0))));
    next.run(request).await
}
{%- if feature_s3 %}

/// Create a test storage operator pointing to local RustFS
fn create_test_storage() -> Operator {
    let builder = opendal::services::S3::default()
        .endpoint("http://localhost:9000")
        .bucket("data")
        .region("us-east-1");

    Operator::new(builder).unwrap().finish()
}
{%- endif %}
