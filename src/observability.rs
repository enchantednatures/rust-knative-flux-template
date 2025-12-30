use opentelemetry::{global, trace::TracerProvider};
use opentelemetry::propagation::TextMapCompositePropagator;
use opentelemetry_sdk::{
    Resource,
    propagation::TraceContextPropagator,
    trace::SdkTracerProvider,
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
pub fn init_telemetry(config: &TelemetryConfig) -> anyhow::Result<Option<SdkTracerProvider>> {
    // =========================================================================
    // CRITICAL: Composite Propagator for Knative Compatibility
    // =========================================================================
    let composite_propagator = TextMapCompositePropagator::new(vec![
        Box::new(TraceContextPropagator::new()), // W3C standard
        Box::new(B3Propagator::new()),           // Zipkin/Knative B3
    ]);
    global::set_text_map_propagator(composite_propagator);

    // Build OTLP exporter if endpoint is configured
    let tracer_provider = if let Some(ref endpoint) = config.otlp_endpoint {
        tracing::info!(endpoint = %endpoint, "Initializing OTLP exporter");

        // OpenTelemetry 0.31: New exporter builder API, no runtime parameter needed
        let exporter = opentelemetry_otlp::SpanExporter::builder()
            .with_tonic()
            .build()
            .map_err(|e| anyhow::anyhow!("Failed to create OTLP exporter: {}", e))?;

        // OpenTelemetry 0.31: Use SdkTracerProvider, no runtime parameter for batch exporter
        let provider = SdkTracerProvider::builder()
            .with_resource(Resource::builder()
                .with_service_name(config.service_name.clone())
                .build())
            .with_batch_exporter(exporter)
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
        // Clone and set globally, return original for shutdown
        global::set_tracer_provider(provider.clone());
        let telemetry_layer = tracing_opentelemetry::layer().with_tracer(tracer);
        registry.with(telemetry_layer).init();
        Ok(Some(provider))
    } else {
        registry.init();
        Ok(None)
    }
}

/// Shutdown telemetry gracefully
///
/// OpenTelemetry 0.31: Explicitly shutdown the tracer provider instead of using global
pub fn shutdown_telemetry(provider: Option<SdkTracerProvider>) {
    if let Some(provider) = provider
        && let Err(e) = provider.shutdown()
    {
        tracing::error!(error = ?e, "Failed to shutdown tracer provider");
    }
}
