//! Compatibility re-export of the shared application state.
//!
//! `AppState` and its single constructor now live in `service-core`; this
//! module keeps the historical `crate::state::AppState` path working.

pub use service_core::state::*;
