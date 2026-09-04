# Cargo-Generate Template Improvements Guide

This document explains how the 9 improvements work within the cargo-generate template system.

## 🎯 Template Overview

This is a **cargo-generate template** that creates production-ready Rust microservices for Knative + FluxCD deployments. The improvements are embedded in the template using Liquid syntax and will be correctly processed when users run:

```bash
cargo generate --git https://github.com/your-org/rust-knative-flux-template
```

## ✅ Improvements & Template Compatibility

### 1. Structured Logging with Contextual Fields
**Template Status:** ✅ Fully Compatible

**How it works:**
- Uses standard Rust code with `tracing` macros
- No Liquid conditionals needed for basic logging
- Feature-gated sections use `{% if feature_kafka %}` syntax

**Generated Output:**
```rust
// In the generated project
tracing::info!(
    event_id = %event_id,
    partition = partition,
    offset = offset,
    topic = %topic,
    "Event published to Kafka successfully"
);
```

---

### 2. Request ID Propagation
**Template Status:** ✅ Fully Compatible

**Template Features:**
- `{{ crate_name }}` placeholder in doc comments for proper crate naming
- Standard Rust code - no feature flags required
- Works in all generated projects regardless of selected features

**Generated Output:**
```rust
// middleware.rs in generated project
use my_service::middleware::request_id_middleware;
```

---

### 3. Input Validation with Validator Crate
**Template Status:** ✅ Fully Compatible

**Template Features:**
- `{{ crate_name }}` in doc test examples
- Validation module always included (security is mandatory)
- Uses `validator` crate with derive macros

**Generated Output:**
```rust
// In generated project
#[derive(Deserialize, ToSchema, Validate)]
pub struct HelloQuery {
    #[validate(length(min = 1, max = 100))]
    pub name: Option<String>,
}
```

---

### 4. Rate Limiting
**Template Status:** ✅ Fully Compatible

**Template Features:**
- Always included (security/performance feature)
- Uses `governor` and `tower_governor` crates
- Configurable in generated code

**Generated Output:**
```rust
// In generated project's routes.rs
let governor_conf = Arc::new(
    rate_limit_config()
        .finish()
        .expect("Failed to build rate limiter configuration")
);
```

---

### 5. Property-Based Testing
**Template Status:** ✅ Fully Compatible

**Template Features:**
- Uses `{{ crate_name }}` for imports in test code
- Feature-gated CloudEvent tests: `{% if feature_kafka %}`
- Tests are in `tests/` directory (integration tests)

**Generated Output:**
```rust
// In generated project's tests/property_tests.rs
use my_service::handlers::validation::is_safe_name;

proptest! {
    #[test]
    fn test_safe_name_validation(name in "[a-zA-Z0-9\\s\\-_]{1,100}") {
        prop_assert!(is_safe_name(&name));
    }
}
```

---

### 6. Contract Testing
**Template Status:** ✅ Fully Compatible

**Template Features:**
- Uses `{{ crate_name }}` for Pact consumer names
- Feature-gated storage tests: `{% if feature_s3 %}`
- Standard Pact tests work in all generated projects

**Generated Output:**
```rust
// In generated project's tests/contract_tests.rs
let pact = PactBuilder::new("consumer-service", "my_service")
    .interaction("a request for hello", "", |mut i| async move {
        // ...
    })
    .await;
```

---

### 7. Chaos Testing Integration
**Template Status:** ✅ Fully Compatible

**Template Features:**
- Uses `{{ project_name }}` for Kubernetes resource names
- Uses `{{ project_name | replace: "_", "-" }}` for Kubernetes labels
- Properly handles hyphen/underscore conversion for K8s compatibility

**Generated Output:**
```yaml
# In generated project's tests/chaos/litmus-chaos-tests.yaml
metadata:
  name: my-service-pod-delete
  namespace: litmus
spec:
  appinfo:
    applabel: 'app.kubernetes.io/name=my-service'
```

---

### 8. Benchmark Tests
**Template Status:** ✅ Fully Compatible

**Template Features:**
- Uses `{{ crate_name }}` for benchmark imports
- Feature-gated S3 benchmarks: `{% if feature_s3 %}`
- Feature-gated Kafka benchmarks: `{% if feature_kafka %}`
- Criterion configuration in `Cargo.toml.liquid`

**Generated Output:**
```rust
// In generated project's benches/handler_benchmarks.rs
use my_service::handlers::validation::is_safe_name;

criterion_group!(benches, benchmark_hello_handler, benchmark_validation);
criterion_main!(benches);
```

---

### 9. Security Headers Middleware
**Template Status:** ✅ Fully Compatible

**Template Features:**
- Standard Rust code - no feature flags needed
- `{{ crate_name }}` in doc comments
- Always included (security is mandatory)

**Generated Output:**
```rust
// In generated project's middleware.rs
response.headers_mut().insert(
    "X-Content-Type-Options",
    HeaderValue::from_static("nosniff"),
);
```

---

## 📦 Dependencies in Template

### Cargo.toml.liquid Structure

```toml
[dependencies]
# ... existing dependencies ...

# Validation - NEW
validator = { version = "0.20", features = ["derive"] }

# Rate Limiting - NEW
governor = "0.8"
tower_governor = "0.7"

# Utilities - NEW
regex = "1.0"
once_cell = "1.0"

{% if feature_kafka %}
# Kafka dependencies (unchanged)
{% endif %}

{% if feature_s3 %}
# S3 dependencies (unchanged)
{% endif %}

[dev-dependencies]
# ... existing dev-dependencies ...

# Property-based testing - NEW
proptest = "1.0"

# Contract testing - NEW
pact_consumer = "0.10"
pact_models = "1.0"

# Benchmarking - NEW
criterion = { version = "0.5", features = ["async_tokio"] }

# Benchmark configuration - NEW
[[bench]]
name = "handler_benchmarks"
harness = false
```

---

## 🎨 Template File Structure

```
template/
├── src/
│   ├── lib.rs                          # Added: middleware module export
│   ├── middleware.rs                   # NEW: Request ID & security headers
│   ├── routes.rs                       # Modified: Added rate limiting
│   ├── handlers/
│   │   ├── api.rs                      # Modified: Added validation
│   │   ├── mod.rs                      # Modified: Added validation module
│   │   └── validation.rs               # NEW: Input validation
│   ├── error.rs                        # Modified: Added Validation/RateLimit errors
│   └── ...
├── tests/
│   ├── property_tests.rs               # NEW: Proptest tests
│   ├── contract_tests.rs               # NEW: Pact tests
│   └── chaos/
│       └── litmus-chaos-tests.yaml     # NEW: Chaos experiments
├── benches/
│   └── handler_benchmarks.rs           # NEW: Criterion benchmarks
├── Cargo.toml.liquid                   # Modified: Added dependencies
└── IMPROVEMENTS_SUMMARY.md             # NEW: Documentation
```

---

## 🔧 Template Variables Used

| Variable | Usage | Example |
|----------|-------|---------|
| `{{ crate_name }}` | Rust crate name (snake_case) | `my_service` |
| `{{ project_name }}` | Project name (user input) | `my-service` or `my_service` |
| `{% raw %}{{ project_name \| replace: "_", "-" }}{% endraw %}` | Kubernetes-compatible name | `my-service` |
| `{% if feature_kafka %}` | Conditional Kafka code | Feature flag |
| `{% if feature_s3 %}` | Conditional S3 code | Feature flag |

---

## 🚀 Generation Examples

### Example 1: Basic Service (No Optional Features)

```bash
cargo generate --git https://github.com/your-org/rust-knative-flux-template
# Project name: my-service
# Features: none selected
```

**Generated Includes:**
- ✅ Structured logging
- ✅ Request ID propagation
- ✅ Input validation
- ✅ Rate limiting (100 req/sec)
- ✅ Security headers
- ✅ Property-based tests
- ✅ Contract tests
- ✅ Benchmarks
- ❌ Kafka-specific tests (skipped via `{% if feature_kafka %}`)
- ❌ S3-specific tests (skipped via `{% if feature_s3 %}`)

### Example 2: Service with Kafka

```bash
cargo generate --git https://github.com/your-org/rust-knative-flux-template
# Project name: event-processor
# Features: feature_kafka=true
```

**Generated Includes:**
- ✅ All base improvements
- ✅ Kafka event publishing
- ✅ Kafka-specific property tests
- ✅ Kafka-specific benchmarks
- ✅ CloudEvent validation tests

### Example 3: Service with S3

```bash
cargo generate --git https://github.com/your-org/rust-knative-flux-template
# Project name: file-service
# Features: feature_s3=true
```

**Generated Includes:**
- ✅ All base improvements
- ✅ S3 storage operations
- ✅ S3-specific property tests
- ✅ S3-specific benchmarks
- ✅ Storage endpoint contract tests

---

## 🧪 Testing the Template

### 1. Generate Test Project

```bash
# Install cargo-generate if not already installed
cargo install cargo-generate

# Generate a test project
cargo generate --path ./rust-knative-flux-template --name test-service
```

### 2. Verify Generated Code Compiles

```bash
cd test-service
cargo check
cargo test
cargo bench
```

### 3. Verify Template Syntax

```bash
# Check for any Liquid syntax errors
cargo generate --path ./rust-knative-flux-template --name syntax-test --silent
```

---

## 📋 Pre-Deployment Checklist

Before publishing the template:

- [ ] All `{% raw %}{{ variable }}{% endraw %}` syntax is valid Liquid
- [ ] Feature conditionals use correct syntax: `{% if feature_name %}`
- [ ] All new files are included in the template
- [ ] Generated code compiles without errors
- [ ] Generated tests pass
- [ ] Benchmarks run successfully
- [ ] Documentation is accurate

---

## 🎓 Best Practices for Template Users

### For Template Authors:

1. **Always use `{{ crate_name }}`** for Rust imports in doc comments
2. **Use feature conditionals** for optional functionality
3. **Test generation** with all feature combinations
4. **Keep dependencies minimal** - only add what's needed

### For Template Users:

1. **Choose features wisely** - each feature adds dependencies
2. **Review generated code** - understand what you're getting
3. **Run tests immediately** - verify the generated project works
4. **Customize rate limits** - adjust for your use case

---

## 🔗 Related Documentation

- [IMPROVEMENTS_SUMMARY.md](./IMPROVEMENTS_SUMMARY.md) - Detailed improvement descriptions
- [cargo-generate documentation](https://cargo-generate.github.io/cargo-generate/)
- [Liquid template syntax](https://shopify.github.io/liquid/)

---

## 💡 Tips for Generated Projects

### Adjusting Rate Limits

Edit `src/routes.rs` in your generated project:

```rust
pub fn rate_limit_config() -> GovernorConfigBuilder<InMemoryState, DefaultClock, NoOpMiddleware> {
    GovernorConfigBuilder::default()
        .per_second(1000)  // Increase for high-traffic services
        .burst_size(100)
        .use_headers()
}
```

### Customizing Security Headers

Edit `src/middleware.rs` in your generated project:

```rust
// Add custom headers
response.headers_mut().insert(
    "X-Custom-Header",
    HeaderValue::from_static("my-value"),
);
```

### Running Chaos Tests

In your generated project:

```bash
# Install Litmus
kubectl apply -f https://litmuschaos.github.io/litmus/litmus-operator-v3.0.0.yaml

# Run chaos tests
kubectl apply -f tests/chaos/litmus-chaos-tests.yaml
```

---

**Note:** The YAML errors shown in `deploy/base/helmrelease.yaml` and `tests/chaos/litmus-chaos-tests.yaml` are expected - they contain Liquid template syntax that will be processed by cargo-generate before being used as YAML.
