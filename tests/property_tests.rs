//! Property-based tests using proptest
//!
//! These tests verify that the application behaves correctly across a wide range of inputs.

use proptest::prelude::*;

// Name validation tests
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

// Serialization/deserialization tests
proptest! {
    #[test]
    fn test_hello_query_serialization(name in "[a-zA-Z0-9\\s\\-_]{1,100}") {
        use {{ crate_name }}::handlers::api::HelloQuery;
        use validator::Validate;

        let query = HelloQuery { name: Some(name) };

        if let Err(e) = query.validate() {
            let error_str = e.to_string();
            prop_assert!(
                error_str.contains("invalid characters") || error_str.contains("between 1 and 100"),
                "Unexpected validation error: {error_str}"
            );
        }
    }

    #[test]
    fn test_health_response_serialization(status in "[a-z]{3,20}") {
        use {{ crate_name }}::handlers::health::HealthResponse;

        let response = HealthResponse { status: status.clone() };
        let json = serde_json::to_string(&response).expect("Should serialize");

        let expected = format!("\"status\":\"{status}\"");
        prop_assert!(json.contains(&expected));

        let deserialized: HealthResponse = serde_json::from_str(&json).expect("Should deserialize");
        prop_assert_eq!(deserialized.status, status);
    }
}

// Error handling tests
proptest! {
    #[test]
    fn test_error_message_format(error_msg in "[a-zA-Z0-9\\s\\-_]{1,200}") {
        use {{ crate_name }}::error::AppError;

        let error = AppError::Internal(error_msg.clone());
        let error_string = error.to_string();

        prop_assert!(error_string.contains(&error_msg));
    }
}

// Input sanitization tests
proptest! {
    #[test]
    fn test_sanitization_preserves_length(input in "[a-zA-Z0-9\\s]{1,100}") {
        use {{ crate_name }}::handlers::validation::sanitize_input;

        let sanitized = sanitize_input(&input);

        if !input.contains('<') && !input.contains('>') && !input.contains('"') && !input.contains('\'') && !input.contains('&') {
            prop_assert_eq!(sanitized, input);
        }
    }

    #[test]
    fn test_sanitization_removes_dangerous_chars(input in "[<>&\"']{1,50}") {
        use {{ crate_name }}::handlers::validation::sanitize_input;

        let sanitized = sanitize_input(&input);

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
            _type in "[a-z.]{5,50}",
            _source in "[a-z/]{5,50}"
        ) {
            {%- if feature_kafka %}
            use {{ crate_name }}::handlers::kafka::CloudEvent;

            let event1 = CloudEvent::new(_type.clone(), _source.clone(), None);
            let event2 = CloudEvent::new(_type, _source, None);

            prop_assert_ne!(event1.id(), event2.id());

            prop_assert_eq!(event1.type_(), event2.type_());
            prop_assert_eq!(event1.source(), event2.source());
            {%- else %}
            let _ = (_type, _source);
            prop_assert!(true);
            {%- endif %}
        }

        #[test]
        fn test_cloud_event_serialization_roundtrip(
            _type in "[a-z.]{5,50}",
            _source in "[a-z/]{5,50}"
        ) {
            {%- if feature_kafka %}
            use {{ crate_name }}::handlers::kafka::CloudEvent;

            let event = CloudEvent::new(_type, _source, None);
            let json = event.to_json().expect("Should serialize");

            prop_assert!(json.contains("specversion"));
            prop_assert!(json.contains("type"));
            prop_assert!(json.contains("source"));
            prop_assert!(json.contains("id"));
            prop_assert!(json.contains("time"));
            {%- else %}
            let _ = (_type, _source);
            prop_assert!(true);
            {%- endif %}
        }
    }
}
