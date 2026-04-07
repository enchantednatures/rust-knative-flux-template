//! Input validation utilities
//!
//! Provides validation helpers and regex patterns for safe input validation.

use once_cell::sync::Lazy;
use regex::Regex;

/// Regex for safe name validation (alphanumeric, spaces, hyphens, underscores)
pub static SAFE_NAME_REGEX: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^[a-zA-Z0-9\s\-_]+$").expect("Invalid regex pattern"));

/// Regex for safe identifier validation (alphanumeric and underscores only)
pub static SAFE_IDENTIFIER_REGEX: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^[a-zA-Z0-9_]+$").expect("Invalid regex pattern"));

/// Regex for email validation (basic)
pub static EMAIL_REGEX: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$").expect("Invalid regex pattern")
});

/// Validates that a string is safe for use as a name
///
/// # Arguments
///
/// * `name` - The string to validate
///
/// # Returns
///
/// `true` if the name is safe, `false` otherwise
///
/// # Examples
///
/// ```
/// use {{ crate_name }}::handlers::validation::is_safe_name;
///
/// assert!(is_safe_name("John Doe"));
/// assert!(is_safe_name("user-123"));
/// assert!(!is_safe_name("<script>alert('xss')</script>"));
/// ```
pub fn is_safe_name(name: &str) -> bool {
    if name.is_empty() || name.len() > 100 {
        return false;
    }
    SAFE_NAME_REGEX.is_match(name)
}

/// Validates that a string is a safe identifier
///
/// # Arguments
///
/// * `id` - The string to validate
///
/// # Returns
///
/// `true` if the identifier is safe, `false` otherwise
pub fn is_safe_identifier(id: &str) -> bool {
    if id.is_empty() || id.len() > 50 {
        return false;
    }
    SAFE_IDENTIFIER_REGEX.is_match(id)
}

/// Validates that a string is a valid email address
///
/// # Arguments
///
/// * `email` - The string to validate
///
/// # Returns
///
/// `true` if the email is valid, `false` otherwise
pub fn is_valid_email(email: &str) -> bool {
    if email.is_empty() || email.len() > 254 {
        return false;
    }
    EMAIL_REGEX.is_match(email)
}

/// Sanitizes a string by removing potentially dangerous characters
///
/// # Arguments
///
/// * `input` - The string to sanitize
///
/// # Returns
///
/// A sanitized version of the input string
///
/// # Examples
///
/// ```
/// use {{ crate_name }}::handlers::validation::sanitize_input;
///
/// let clean = sanitize_input("<script>alert('xss')</script>");
/// assert!(!clean.contains('<'));
/// assert!(!clean.contains('>'));
/// ```
pub fn sanitize_input(input: &str) -> String {
    input
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#x27;")
        .replace('&', "&amp;")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_safe_name() {
        assert!(is_safe_name("John Doe"));
        assert!(is_safe_name("user-123"));
        assert!(is_safe_name("test_name"));
        assert!(is_safe_name("Hello World"));

        assert!(!is_safe_name(""));
        assert!(!is_safe_name("a".repeat(101).as_str()));
        assert!(!is_safe_name("<script>"));
        assert!(!is_safe_name("alert('xss')"));
    }

    #[test]
    fn test_is_safe_identifier() {
        assert!(is_safe_identifier("user123"));
        assert!(is_safe_identifier("test_name"));
        assert!(is_safe_identifier("ABC"));

        assert!(!is_safe_identifier(""));
        assert!(!is_safe_identifier("a".repeat(51).as_str()));
        assert!(!is_safe_identifier("user-name"));
        assert!(!is_safe_identifier("user name"));
    }

    #[test]
    fn test_is_valid_email() {
        assert!(is_valid_email("test@example.com"));
        assert!(is_valid_email("user.name@domain.co.uk"));
        assert!(is_valid_email("user+tag@example.com"));

        assert!(!is_valid_email(""));
        assert!(!is_valid_email("invalid"));
        assert!(!is_valid_email("@example.com"));
        assert!(!is_valid_email("test@"));
    }

    #[test]
    fn test_sanitize_input() {
        assert_eq!(sanitize_input("<script>"), "&lt;script&gt;");
        assert_eq!(sanitize_input("\"test\""), "&quot;test&quot;");
        assert_eq!(sanitize_input("'test'"), "&#x27;test&#x27;");
        assert_eq!(sanitize_input("&"), "&amp;");
        assert_eq!(sanitize_input("normal text"), "normal text");
    }
}
