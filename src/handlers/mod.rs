pub mod api;
pub mod events;
pub mod health;
{%- if features contains "s3" %}
pub mod storage;
{%- endif %}
{%- if enable_kafka_publishing %}
pub mod kafka;
{%- endif %}
