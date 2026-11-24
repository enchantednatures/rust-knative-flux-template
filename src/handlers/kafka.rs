//! Kafka event construction for this service.
//!
//! The transport plumbing (`CloudEvent`, `KafkaPublisher`) lives in
//! `service-core`; this module keeps the service-specific demo event factory
//! and re-exports the publisher types handlers already use.

use crate::config::KafkaConfig;

pub use service_core::kafka::{CloudEvent, KafkaPublisher};

/// Creates a dummy CloudEvent for testing and basic usage
///
/// # Arguments
///
/// * `config` - Kafka configuration containing event_name
/// * `source` - Source path (e.g., handler path)
///
/// # Returns
///
/// A CloudEvent with minimal dummy data
pub fn create_dummy_event(config: &KafkaConfig, source: impl Into<String>) -> CloudEvent {
    let dummy_data = serde_json::json!({
        "message": "Event published from handler",
        "timestamp": chrono::Utc::now().to_rfc3339()
    });

    CloudEvent::new(config.event_name.clone(), source.into(), Some(dummy_data))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_dummy_event_creation() {
        let config = KafkaConfig {
            broker_url: "localhost:9092".to_string(),
            topic: "test-events".to_string(),
            event_name: "com.example.dummy".to_string(),
            compression: "snappy".to_string(),
            linger_ms: 5,
            retries: 3,
            timeout_ms: 10000,
        };

        let event = create_dummy_event(&config, "/api/v1/handler");

        assert_eq!(event.type_, "com.example.dummy");
        assert_eq!(event.source, "/api/v1/handler");
        assert!(event.data.is_some());
        assert_eq!(event.specversion, "1.0");
    }
}
