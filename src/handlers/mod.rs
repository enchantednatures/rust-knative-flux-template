pub mod api;
pub mod events;
pub mod health;
{%- if feature_postgres %}
pub mod items;
{%- endif %}
{%- if feature_kafka %}
pub mod kafka;
{%- endif %}
{%- if feature_s3 %}
pub mod storage;
{%- endif %}
{%- if workload_type == "Deployment" %}
pub mod stream;
{%- endif %}
pub mod validation;
