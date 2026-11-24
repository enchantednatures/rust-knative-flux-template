pub mod handlers;
pub mod routes;
pub mod state;

// Shared infrastructure lives in the `service-core` workspace crate. Re-export
// the modules handlers historically imported from this crate's root so their
// import paths (and this crate's public API) stay stable.
pub use service_core::{bootstrap, config, error, health, middleware, observability};
{%- if feature_s3 %}

// Re-export OpenDAL Operator for storage operations
pub use opendal::Operator;
{%- endif %}
