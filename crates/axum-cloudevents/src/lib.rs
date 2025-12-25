//! CloudEvents extractors for Axum web framework.
//!
//! Provides structured CloudEvents parsing and type-safe event handling for Axum handlers,
//! with support for both simple payload extraction and tagged enum routing.
//!
//! # Example
//!
//! ```ignore
//! use axum::Json;
//! use axum_cloudevents::CloudEvent;
//! use serde::Deserialize;
//!
//! #[derive(Deserialize)]
//! struct Ping {
//!     message: String,
//! }
//!
//! async fn handler(event: CloudEvent<Ping>) -> Json<Pong> {
//!     Json(Pong {
//!         reply: format!("pong: {}", event.data.message),
//!         event_id: event.id().to_string(),
//!     })
//! }
//! ```

pub use extractor::CloudEvent;
pub use metadata::CloudEventMetadata;
pub use error::CloudEventError;
pub use headers::*;

#[cfg(feature = "macros")]
pub use axum_cloudevents_macros::CloudEventTagged;

mod extractor;
mod metadata;
mod error;
mod headers;
