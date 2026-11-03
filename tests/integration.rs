//! Integration test harness.
//!
//! Pulls the feature-gated suites from `tests/integration/` into one compiled
//! cargo test target, so no file in that directory is dead code. The liquid
//! tags are processed at generate time; with the corresponding feature off this
//! file intentionally contains no modules and compiles as an empty test target.
//!
//! Suites that need live infrastructure are `#[ignore]`d. Run them with:
//!
//! ```bash
//! cargo test --all-features -- --ignored --test-threads=1
//! ```
//!
//! CI does exactly that in the `integration-tests` job (Redis + RustFS +
//! PostgreSQL containers on the runner's Docker daemon).
{%- if feature_postgres %}
#[path = "integration/postgres_test.rs"]
mod postgres_test;

#[path = "integration/postgres_integration_test.rs"]
mod postgres_integration_test;
{%- endif %}
{%- if feature_kafka %}
#[path = "integration/kafka_publishing_test.rs"]
mod kafka_publishing_test;
{%- endif %}
