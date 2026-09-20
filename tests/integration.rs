//! Integration test harness.
//!
//! Pulls feature-gated test suites from `tests/integration/` into a compiled
//! cargo test target. The liquid tags in this file are processed at generate
//! time; with the corresponding feature off this file intentionally contains
//! no modules and compiles as an empty test target.
{%- if feature_postgres %}
#[path = "integration/postgres_test.rs"]
mod postgres_test;
{%- endif %}
