//! HTTP middleware for cross-cutting concerns
//!
//! Provides:
//! - Request ID propagation for distributed tracing
//! - Security headers for HTTP responses
//! - Request/response logging with contextual fields

use axum::{
    body::Body,
    extract::Request,
    http::HeaderValue,
    middleware::Next,
    response::Response,
};
use std::time::Instant;
use tracing::Span;
use uuid::Uuid;

/// Request ID header name (standard header for request correlation)
pub const REQUEST_ID_HEADER: &str = "x-request-id";

/// Extract or generate a request ID for distributed tracing
///
/// This middleware:
/// 1. Checks for existing request ID in headers (from upstream services)
/// 2. Generates a new UUID if not present
/// 3. Adds the request ID to the response headers
/// 4. Adds the request ID to the tracing span for correlation
///
/// # Example
/// ```
/// use axum::Router;
/// use {{ crate_name }}::middleware::request_id_middleware;
///
/// let app = Router::new()
///     .layer(axum::middleware::from_fn(request_id_middleware));
/// ```
pub async fn request_id_middleware(req: Request<Body>, next: Next) -> Response {
    // Extract existing request ID or generate new one
    let request_id = req
        .headers()
        .get(REQUEST_ID_HEADER)
        .and_then(|value| value.to_str().ok())
        .map(|s| s.to_string())
        .unwrap_or_else(|| Uuid::new_v4().to_string());

    // Add request ID to tracing span for correlation
    Span::current().record("request_id", &request_id.as_str());

    // Log request start with contextual fields
    let start = Instant::now();
    let method = req.method().to_string();
    let uri = req.uri().to_string();
    let version = format!("{:?}", req.version());

    tracing::info!(
        request_id = %request_id,
        method = %method,
        uri = %uri,
        version = %version,
        "Request started"
    );

    // Execute the request
    let mut response = next.run(req).await;

    // Calculate duration
    let duration_ms = start.elapsed().as_millis() as u64;
    let status = response.status().as_u16();

    // Add request ID to response headers
    if let Ok(header_value) = HeaderValue::from_str(&request_id) {
        response.headers_mut().insert(REQUEST_ID_HEADER, header_value);
    }

    // Log request completion with contextual fields
    tracing::info!(
        request_id = %request_id,
        method = %method,
        uri = %uri,
        status = status,
        duration_ms = duration_ms,
        "Request completed"
    );

    response
}

/// Security headers middleware
///
/// Adds essential security headers to all HTTP responses:
/// - X-Content-Type-Options: nosniff
/// - X-Frame-Options: DENY
/// - X-XSS-Protection: 1; mode=block
/// - Strict-Transport-Security (HSTS)
/// - Content-Security-Policy
/// - Referrer-Policy
/// - Permissions-Policy
///
/// # Example
/// ```
/// use axum::Router;
/// use {{ crate_name }}::middleware::security_headers_middleware;
///
/// let app = Router::new()
///     .layer(axum::middleware::from_fn(security_headers_middleware));
/// ```
pub async fn security_headers_middleware(req: Request<Body>, next: Next) -> Response {
    let mut response = next.run(req).await;

    // Prevent MIME type sniffing
    response.headers_mut().insert(
        "X-Content-Type-Options",
        HeaderValue::from_static("nosniff"),
    );

    // Prevent clickjacking
    response.headers_mut().insert(
        "X-Frame-Options",
        HeaderValue::from_static("DENY"),
    );

    // Enable XSS filter in browsers
    response.headers_mut().insert(
        "X-XSS-Protection",
        HeaderValue::from_static("1; mode=block"),
    );

    // HSTS - force HTTPS (only in production)
    // Note: In production, adjust max-age appropriately (e.g., 31536000 for 1 year)
    response.headers_mut().insert(
        "Strict-Transport-Security",
        HeaderValue::from_static("max-age=31536000; includeSubDomains"),
    );

    // Content Security Policy - restrict resource loading
    response.headers_mut().insert(
        "Content-Security-Policy",
        HeaderValue::from_static("default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; media-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self';"),
    );

    // Referrer Policy
    response.headers_mut().insert(
        "Referrer-Policy",
        HeaderValue::from_static("strict-origin-when-cross-origin"),
    );

    // Permissions Policy - restrict browser features
    response.headers_mut().insert(
        "Permissions-Policy",
        HeaderValue::from_static("accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()"),
    );

    response
}

/// Combined middleware that applies both request ID and security headers
///
/// This is a convenience middleware that applies both request_id_middleware
/// and security_headers_middleware in the correct order.
///
/// # Example
/// ```
/// use axum::Router;
/// use {{ crate_name }}::middleware::common_middleware;
///
/// let app = Router::new()
///     .layer(axum::middleware::from_fn(common_middleware));
/// ```
pub async fn common_middleware(req: Request<Body>, next: Next) -> Response {
    // First apply request ID logic
    let request_id = req
        .headers()
        .get(REQUEST_ID_HEADER)
        .and_then(|value| value.to_str().ok())
        .map(|s| s.to_string())
        .unwrap_or_else(|| Uuid::new_v4().to_string());

    Span::current().record("request_id", &request_id.as_str());

    let start = Instant::now();
    let method = req.method().to_string();
    let uri = req.uri().to_string();

    tracing::info!(
        request_id = %request_id,
        method = %method,
        uri = %uri,
        "Request started"
    );

    // Execute request
    let mut response = next.run(req).await;

    // Add request ID to response
    if let Ok(header_value) = HeaderValue::from_str(&request_id) {
        response.headers_mut().insert(REQUEST_ID_HEADER, header_value);
    }

    // Add security headers
    response.headers_mut().insert(
        "X-Content-Type-Options",
        HeaderValue::from_static("nosniff"),
    );
    response.headers_mut().insert(
        "X-Frame-Options",
        HeaderValue::from_static("DENY"),
    );
    response.headers_mut().insert(
        "X-XSS-Protection",
        HeaderValue::from_static("1; mode=block"),
    );
    response.headers_mut().insert(
        "Strict-Transport-Security",
        HeaderValue::from_static("max-age=31536000; includeSubDomains"),
    );
    response.headers_mut().insert(
        "Content-Security-Policy",
        HeaderValue::from_static("default-src 'self'"),
    );
    response.headers_mut().insert(
        "Referrer-Policy",
        HeaderValue::from_static("strict-origin-when-cross-origin"),
    );

    // Log completion
    let duration_ms = start.elapsed().as_millis() as u64;
    let status = response.status().as_u16();

    tracing::info!(
        request_id = %request_id,
        method = %method,
        uri = %uri,
        status = status,
        duration_ms = duration_ms,
        "Request completed"
    );

    response
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::to_bytes;
    use axum::routing::get;
    use axum::Router;
    use tower::ServiceExt;

    async fn test_handler() -> &'static str {
        "OK"
    }

    #[tokio::test]
    async fn test_request_id_generation() {
        let app = Router::new()
            .route("/test", get(test_handler))
            .layer(axum::middleware::from_fn(request_id_middleware));

        let response = app
            .oneshot(
                axum::http::Request::builder()
                    .uri("/test")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        // Check that response has request ID header
        assert!(response.headers().contains_key(REQUEST_ID_HEADER));
        let request_id = response
            .headers()
            .get(REQUEST_ID_HEADER)
            .unwrap()
            .to_str()
            .unwrap();
        assert!(!request_id.is_empty());
        // Should be a valid UUID
        assert!(Uuid::parse_str(request_id).is_ok());
    }

    #[tokio::test]
    async fn test_request_id_propagation() {
        let app = Router::new()
            .route("/test", get(test_handler))
            .layer(axum::middleware::from_fn(request_id_middleware));

        let existing_id = "test-request-id-123";
        let response = app
            .oneshot(
                axum::http::Request::builder()
                    .uri("/test")
                    .header(REQUEST_ID_HEADER, existing_id)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        // Should preserve existing request ID
        let request_id = response
            .headers()
            .get(REQUEST_ID_HEADER)
            .unwrap()
            .to_str()
            .unwrap();
        assert_eq!(request_id, existing_id);
    }

    #[tokio::test]
    async fn test_security_headers() {
        let app = Router::new()
            .route("/test", get(test_handler))
            .layer(axum::middleware::from_fn(security_headers_middleware));

        let response = app
            .oneshot(
                axum::http::Request::builder()
                    .uri("/test")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        // Check all security headers are present
        assert_eq!(
            response.headers().get("X-Content-Type-Options").unwrap(),
            "nosniff"
        );
        assert_eq!(
            response.headers().get("X-Frame-Options").unwrap(),
            "DENY"
        );
        assert_eq!(
            response.headers().get("X-XSS-Protection").unwrap(),
            "1; mode=block"
        );
        assert!(response
            .headers()
            .get("Strict-Transport-Security")
            .unwrap()
            .to_str()
            .unwrap()
            .contains("max-age="));
        assert!(response
            .headers()
            .get("Content-Security-Policy")
            .is_some());
        assert!(response
            .headers()
            .get("Referrer-Policy")
            .is_some());
    }

    #[tokio::test]
    async fn test_common_middleware() {
        let app = Router::new()
            .route("/test", get(test_handler))
            .layer(axum::middleware::from_fn(common_middleware));

        let response = app
            .oneshot(
                axum::http::Request::builder()
                    .uri("/test")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        // Should have both request ID and security headers
        assert!(response.headers().contains_key(REQUEST_ID_HEADER));
        assert!(response.headers().contains_key("X-Content-Type-Options"));
        assert!(response.headers().contains_key("X-Frame-Options"));
    }
}
