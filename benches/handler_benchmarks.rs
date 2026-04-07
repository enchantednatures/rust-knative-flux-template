//! Benchmark tests using Criterion
//!
//! Run with: `cargo bench`
//!
//! These benchmarks measure the performance of critical paths in the application.

use criterion::{Criterion, Throughput, black_box, criterion_group, criterion_main};
use tokio::runtime::Runtime;

fn benchmark_hello_handler(c: &mut Criterion) {
    let rt = Runtime::new().unwrap();

    let mut group = c.benchmark_group("hello_handler");
    group.throughput(Throughput::Elements(1));

    group.bench_function("hello_world", |b| {
        b.to_async(&rt).iter(|| async {
            let name = "World";
            let message = format!("Hello, {}!", name);
            black_box(message)
        });
    });

    group.bench_function("hello_with_name", |b| {
        b.to_async(&rt).iter(|| async {
            let name = "Alice";
            let message = format!("Hello, {}!", name);
            black_box(message)
        });
    });

    group.finish();
}

fn benchmark_validation(c: &mut Criterion) {
    let mut group = c.benchmark_group("validation");

    group.bench_function("safe_name_valid", |b| {
        use {{ crate_name }}::handlers::validation::is_safe_name;

        b.iter(|| {
            let name = "John Doe-123_test";
            black_box(is_safe_name(black_box(name)))
        });
    });

    group.bench_function("safe_name_invalid", |b| {
        use {{ crate_name }}::handlers::validation::is_safe_name;

        b.iter(|| {
            let name = "<script>alert('xss')</script>";
            black_box(is_safe_name(black_box(name)))
        });
    });

    group.bench_function("email_validation", |b| {
        use {{ crate_name }}::handlers::validation::is_valid_email;

        b.iter(|| {
            let email = "test@example.com";
            black_box(is_valid_email(black_box(email)))
        });
    });

    group.bench_function("input_sanitization", |b| {
        use {{ crate_name }}::handlers::validation::sanitize_input;

        b.iter(|| {
            let input = "<script>alert('xss')</script>";
            black_box(sanitize_input(black_box(input)))
        });
    });

    group.finish();
}

fn benchmark_serialization(c: &mut Criterion) {
    let mut group = c.benchmark_group("serialization");

    group.bench_function("health_response_serialize", |b| {
        use {{ crate_name }}::handlers::health::HealthResponse;

        let response = HealthResponse {
            status: "ready".to_string(),
        };

        b.iter(|| black_box(serde_json::to_string(black_box(&response)).unwrap()));
    });

    group.bench_function("health_response_deserialize", |b| {
        use {{ crate_name }}::handlers::health::HealthResponse;

        let json = r#"{"status":"ready"}"#;

        b.iter(|| black_box(serde_json::from_str::<HealthResponse>(black_box(json)).unwrap()));
    });

    {%- if feature_kafka %}
    group.bench_function("cloud_event_serialize", |b| {
        use {{ crate_name }}::handlers::kafka::CloudEvent;

        let event = CloudEvent::new(
            "com.example.test".to_string(),
            "/api/v1/test".to_string(),
            Some(serde_json::json!({"message": "test"})),
        );

        b.iter(|| black_box(event.to_json().unwrap()));
    });
    {%- endif %}

    group.finish();
}

fn benchmark_error_handling(c: &mut Criterion) {
    let mut group = c.benchmark_group("error_handling");

    group.bench_function("error_creation", |b| {
        use {{ crate_name }}::error::AppError;

        b.iter(|| {
            let error = AppError::Internal("Test error".to_string());
            black_box(error)
        });
    });

    group.bench_function("error_conversion", |b| {
        use axum::response::IntoResponse;
        use {{ crate_name }}::error::AppError;

        let error = AppError::Internal("Test error".to_string());

        b.iter(|| {
            let response = error.clone().into_response();
            black_box(response)
        });
    });

    group.finish();
}

fn benchmark_middleware(c: &mut Criterion) {
    let mut group = c.benchmark_group("middleware");

    group.bench_function("request_id_generation", |b| {
        use uuid::Uuid;

        b.iter(|| black_box(Uuid::new_v4().to_string()));
    });

    group.bench_function("security_headers", |b| {
        use axum::http::HeaderValue;

        b.iter(|| {
            let headers = vec![
                (
                    "X-Content-Type-Options",
                    HeaderValue::from_static("nosniff"),
                ),
                ("X-Frame-Options", HeaderValue::from_static("DENY")),
                (
                    "X-XSS-Protection",
                    HeaderValue::from_static("1; mode=block"),
                ),
            ];
            black_box(headers)
        });
    });

    group.finish();
}

{%- if feature_s3 %}
fn benchmark_s3_operations(c: &mut Criterion) {
    let rt = Runtime::new().unwrap();

    let mut group = c.benchmark_group("s3_operations");

    group.bench_function("storage_data_creation", |b| {
        use {{ crate_name }}::handlers::storage::StorageTestData;

        b.to_async(&rt).iter(|| async {
            let data = StorageTestData {
                message: "Test message".to_string(),
                timestamp: chrono::Utc::now().to_rfc3339(),
                test_id: uuid::Uuid::new_v4().to_string(),
            };
            black_box(data)
        });
    });

    group.bench_function("json_serialization", |b| {
        use {{ crate_name }}::handlers::storage::StorageTestData;

        let data = StorageTestData {
            message: "Test message".to_string(),
            timestamp: "2024-01-01T00:00:00Z".to_string(),
            test_id: "test-uuid".to_string(),
        };

        b.iter(|| black_box(serde_json::to_vec(black_box(&data)).unwrap()));
    });

    group.finish();
}
{%- endif %}

fn benchmark_rate_limiting(c: &mut Criterion) {
    let mut group = c.benchmark_group("rate_limiting");

    group.bench_function("quota_check", |b| {
        use governor::{Quota, RateLimiter};
        use std::num::NonZeroU32;
        use std::sync::Arc;

        let quota = Quota::per_second(NonZeroU32::new(100).unwrap());
        let limiter = Arc::new(RateLimiter::direct(quota));

        b.iter(|| black_box(limiter.check().is_ok()));
    });

    group.finish();
}

criterion_group!(
    benches,
    benchmark_hello_handler,
    benchmark_validation,
    benchmark_serialization,
    benchmark_error_handling,
    benchmark_middleware,
    {%- if feature_s3 %}
    benchmark_s3_operations,
    {%- endif %}
    benchmark_rate_limiting
);

criterion_main!(benches);
