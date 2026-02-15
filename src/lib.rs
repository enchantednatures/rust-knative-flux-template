pub mod config;
pub mod error;
pub mod handlers;
pub mod observability;
pub mod routes;
pub mod state;
{%- if feature_s3 %}

// Re-export OpenDAL Operator for storage operations
pub use opendal::Operator;
{%- endif %}
