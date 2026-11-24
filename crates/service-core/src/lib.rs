//! Shared infrastructure for services generated from the Rust Knative + FluxCD
//! template.
//!
//! The crate is infrastructure-only: configuration, error types, application
//! state, observability, HTTP middleware, health endpoints, the Kafka
//! publisher, and the startup bootstrap helpers.
//!
//! Heavy dependencies are optional so a service pays only for what it uses:
//!
//! - `postgres`: `sqlx` pool + migration runner support
//! - `s3`: OpenDAL S3-compatible operator
//! - `kafka`: CloudEvent + Kafka publisher plumbing

pub mod bootstrap;
pub mod config;
pub mod error;
pub mod health;
#[cfg(feature = "kafka")]
pub mod kafka;
pub mod middleware;
pub mod observability;
pub mod state;

#[cfg(feature = "s3")]
pub use opendal::Operator;
