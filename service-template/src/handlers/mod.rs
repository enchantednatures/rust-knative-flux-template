pub mod api;
{%- if kafka_source %}
pub mod events;
{%- endif %}

// Health endpoints are infrastructure: they live in `service-core` and are
// re-exported here so `handlers::health::*` paths keep working.
pub use service_core::health;
