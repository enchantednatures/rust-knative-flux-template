pub mod api;
pub mod events;
pub mod health;
{%- if features contains "s3" %}
pub mod storage;
{%- endif %}
{%- if "kafka" in features %}
pub mod kafka;
{%- endif %}
