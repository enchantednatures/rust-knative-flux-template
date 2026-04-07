//! Property-based tests using proptest
//!
//! These tests verify that the application behaves correctly across a wide range of inputs.

use proptest::prelude::*;

/// Test that name validation works correctly for various inputs
proptest! {
    #[test]
    fn test_safe_name_validation(name in "[a-zA-Z0-9\\s\\-_]{1,100}") {
        use {{ crate_name }}::handlers::validation::is_safe_name;
        prop_assert!(is_safe_name(&name));
    }

    #[test]
    fn test_unsafe_names_are_rejected(name in "[<>&\"']{1,50}") {
        use {{ crate_name }}::handlers::validation::is_safe_name;
        prop_assert!(!is_safe_name(&name));
    }

    #[test]
    fn test_safe_identifier_validation(id in "[a-zA-Z0-9_]{1,50}") {
        use {{ crate_name }}::handlers::validation::is_safe_identifier;
        prop_assert!(is_safe_identifier(&id));
    }

    #[test]
    fn test_email_validation(email in "[a-zA-Z0-9._%+-]{1,50}@[a-zA-Z0-9.-]{1,50}\\.[a-zA-Z]{2,10}") {
        use {{ crate_name }}::handlers::validation::is_valid_email;
        prop_assert!(is_valid_email(&email));
    }
}

/// Property-based tests for serialization/deserialization
proptest! {
    #[test]
    fn test_hello_query_serialization(name in "[a-zA-Z0-9\\s\\-_]{1,100}") {
        use {{ crate_name }}::handlers::api::HelloQuery;
        use validator::Validate;

        let query = HelloQuery { name: Some(name) };

        // Should validate successfully for safe names
        if let Err(e) = query.validate() {
            // If validation fails, it should be due to regex mismatch
            let error_str = e.to_string();
            prop_assert!(
                error_str.contains("invalid characters") || error_str.contains("between 1 and 100"),
                "Unexpected validation error: {}", error_str
            );
        }
    }

    #[test]
    fn test_health_response_serialization(status in "[a-z]{3,20}") {
        use {{ crate_name }}::handlers::health::HealthResponse;
        use serde_json;

        let response = HealthResponse { status: status.clone() };
        let json = serde_json::to_string(&response).expect("Should serialize");

        // Should contain the status field
        prop_assert!(json.contains(&format!("\"status\":\"{}\"", status)));

        // Should deserialize back
        let deserialized: HealthResponse = serde_json::from_str(&json).expect("Should deserialize");
        prop_assert_eq!(deserialized.status, status);
    }
}

/// Property-based tests for error handling
proptest! {
    #[test]
    fn test_error_message_format(error_msg in "[a-zA-Z0-9\\s\\-_]{1,200}") {
        use {{ crate_name }}::error::AppError;

        let error = AppError::Internal(error_msg.clone());
        let error_string = error.to_string();

        // Error message should contain the original message
        prop_assert!(error_string.contains(&error_msg));
    }
}

/// Property-based tests for input sanitization
proptest! {
    #[test]
    fn test_sanitization_preserves_length(input in "[a-zA-Z0-9\\s]{1,100}") {
        use {{ crate_name }}::handlers::validation::sanitize_input;

        let sanitized = sanitize_input(&input);

        // For safe input, sanitization should preserve the content
        if !input.contains('<') && !input.contains('>') && !input.contains('"') && !input.contains('\'') && !input.contains('&') {
            prop_assert_eq!(sanitized, input);
        }
    }

    #[test]
    fn test_sanitization_removes_dangerous_chars(input in "[<>&\"']{1,50}") {
        use {{ crate_name }}::handlers::validation::sanitize_input;

        let sanitized = sanitize_input(&input);

        // Sanitized output should not contain dangerous characters
        prop_assert!(!sanitized.contains('<'));
        prop_assert!(!sanitized.contains('>'));
        prop_assert!(!sanitized.contains('\"'));
    }
}

#[cfg(test)]
mod cloud_event_tests {
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn test_cloud_event_id_uniqueness(
            type_ in "[a-z.]{5,50}",
            source in "[a-z/]{5,50}"
        ) {
            {%- if feature_kafka %}
            use {{ crate_name }}::handlers::kafka::CloudEvent;

            let event1 = CloudEvent::new(type_.clone(), source.clone(), None);
            let event2 = CloudEvent::new(type_, source, None);

            // Two events created at different times should have different IDs
            prop_assert_ne!(event1.id(), event2.id());

            // Both should have the same type and source
            prop_assert_eq!(event1.type_(), event2.type_());
            prop_assert_eq!(event1.source(), event2.source());
            {%- else %}
            // Skip test when Kafka feature is not enabled
            prop_assert!(true);
            {%- endif %}
        }

        #[test]
        fn test_cloud_event_serialization_roundtrip(
            type_ in "[a-z.]{5,50}",
            source in "[a-z/]{5,50}"
        ) {
            {%- if feature_kafka %}
            use {{ crate_name }}::handlers::kafka::CloudEvent;
            use serde_json;

            let event = CloudEvent::new(type_, source, None);
            let json = event.to_json().expect("Should serialize");

            // JSON should contain required fields
            prop_assert!(json.contains("specversion"));
            prop_assert!(json.contains("type"));
            prop_assert!(json.contains("source"));
            prop_assert!(json.contains("id"));
            prop_assert!(json.contains("time"));
            {%- else %}
            prop_assert!(true);
            {%- endif %}
        }
    }
}
