//! Thin service library.
//!
//! All infrastructure (configuration, errors, state, observability, HTTP
//! middleware, health endpoints, Kafka plumbing, and startup bootstrap) lives
//! in the shared `service-core` crate. This crate only owns its HTTP routes
//! and demo handlers.

pub mod handlers;
pub mod routes;

pub use service_core::{bootstrap, config, error, health, middleware, observability, state};
