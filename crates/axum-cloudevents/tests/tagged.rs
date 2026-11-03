//! Behaviour of the `CloudEventTagged` derive macro.
//!
//! The derive lives in `axum-cloudevents-macros`; it can only be exercised from
//! a crate that depends on it, so the coverage lives here.

use axum_cloudevents::CloudEventTagged;
use serde::Deserialize;
use serde_json::json;

#[derive(Debug, Deserialize, PartialEq)]
struct CreatedPayload {
    id: String,
}

#[derive(Debug, Deserialize, PartialEq)]
struct DeletedPayload {
    id: String,
}

#[derive(Debug, CloudEventTagged, PartialEq)]
#[cloud_event_prefix = "com.example.thing"]
enum ThingEvent {
    #[cloud_event_type("created")]
    Created(CreatedPayload),
    #[cloud_event_type("deleted")]
    Deleted(DeletedPayload),
}

#[test]
fn routes_a_prefixed_event_type_to_its_variant() {
    let event =
        ThingEvent::from_cloud_event_parts("com.example.thing.created", json!({ "id": "thing-1" }))
            .expect("known event type");

    assert_eq!(
        event,
        ThingEvent::Created(CreatedPayload {
            id: "thing-1".to_string()
        })
    );
}

#[test]
fn routes_a_bare_suffix_to_its_variant() {
    let event =
        ThingEvent::from_cloud_event_parts("deleted", json!({ "id": "thing-2" })).expect("suffix");

    assert_eq!(
        event,
        ThingEvent::Deleted(DeletedPayload {
            id: "thing-2".to_string()
        })
    );
}

#[test]
fn rejects_an_unknown_event_type_with_the_original_value() {
    let err = ThingEvent::from_cloud_event_parts("com.example.other", json!({}))
        .expect_err("unknown type must fail");

    assert!(err.contains("com.example.other"), "unexpected error: {err}");
}

#[test]
fn rejects_a_payload_that_does_not_match_the_variant() {
    let err = ThingEvent::from_cloud_event_parts("com.example.thing.created", json!({ "nope": 1 }))
        .expect_err("payload mismatch must fail");

    assert!(!err.is_empty());
}
