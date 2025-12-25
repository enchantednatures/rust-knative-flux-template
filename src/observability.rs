use opentelemetry::{KeyValue, global, trace::TracerProvider};
use opentelemetry_sdk::{
    Resource,
    propagation::TraceContextPropagator,
    trace::{Config, Sampler},
};
use opentelemetry_zipkin::Propagator as B3Propagator;
use tracing_subscriber::{EnvFilter, layer::SubscriberExt, util::SubscriberInitExt};

use crate::config::TelemetryConfig;

/// Initialize OpenTelemetry with B3 propagation for Knative compatibility
///
/// # Critical: Knative Trace Propagation
///
/// Knative's infrastructure (activator, queue-proxy) uses Zipkin B3 headers for tracing:
/// - X-B3-TraceId
/// - X-B3-SpanId
/// - X-B3-ParentSpanId
/// - X-B3-Sampled
///
/// Without B3 propagation, your application traces will be DISCONNECTED from
/// Knative's infrastructure traces.
///
/// Solution: Use a composite propagator that supports BOTH:
/// 1. W3C TraceContext (modern standard)
/// 2. B3 (Zipkin/Knative compatibility)
///
/// This ensures traces propagate correctly through:
/// External Client -> Knative Ingress -> Activator -> Queue-Proxy -> Your App
pub fn init_telemetry(config: &TelemetryConfig) -> anyhow::Result<()> {
    // =========================================================================
    // CRITICAL: Composite Propagator for Knative Compatibility
    // =========================================================================
    let composite_propagator =
        opentelemetry_sdk::propagation::TextMapCompositePropagator::new(vec![
            Box::new(TraceContextPropagator::new()), // W3C standard
            Box::new(B3Propagator::new()),           // Zipkin/Knative B3
        ]);
    global::set_text_map_propagator(composite_propagator);

    // Build OTLP exporter if endpoint is configured
    let tracer_provider = if let Some(ref endpoint) = config.otlp_endpoint {
        tracing::info!(endpoint = %endpoint, "Initializing OTLP exporter");

        let exporter =
            opentelemetry_otlp::SpanExporter::new_tonic(Default::default(), Default::default())
                .map_err(|e| anyhow::anyhow!("Failed to create OTLP exporter: {}", e))?;

        let provider = opentelemetry_sdk::trace::TracerProvider::builder()
            .with_batch_exporter(exporter, opentelemetry_sdk::runtime::Tokio)
            .with_config(
                Config::default()
                    .with_sampler(Sampler::AlwaysOn)
                    .with_resource(Resource::new(vec![KeyValue::new(
                        opentelemetry_semantic_conventions::resource::SERVICE_NAME,
                        config.service_name.clone(),
                    )])),
            )
            .build();

        Some(provider)
    } else {
        tracing::info!("OTLP endpoint not configured, traces will only be logged");
        None
    };

    // Set up tracing subscriber
    let env_filter =
        EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(&config.log_level));

    let fmt_layer = tracing_subscriber::fmt::layer()
        .json()
        .with_target(true)
        .with_thread_ids(true);

    let registry = tracing_subscriber::registry()
        .with(env_filter)
        .with(fmt_layer);

    if let Some(provider) = tracer_provider {
        let tracer = provider.tracer(config.service_name.clone());
        global::set_tracer_provider(provider);
        let telemetry_layer = tracing_opentelemetry::layer().with_tracer(tracer);
        registry.with(telemetry_layer).init();
    } else {
        registry.init();
    }

    Ok(())
}

/// Shutdown telemetry gracefully
pub fn shutdown_telemetry() {
    global::shutdown_tracer_provider();
}
