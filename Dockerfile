# ==============================================================================
# Stage 1: Build
# ==============================================================================
FROM rust:1.92-alpine AS builder

# Install build dependencies for musl static compilation
RUN apk add --no-cache \
    musl-dev \
    openssl-dev \
    openssl-libs-static \
    pkgconfig

WORKDIR /app

# Install the musl target for static linking
RUN rustup target add x86_64-unknown-linux-musl

# Copy manifests first for dependency caching
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./

# Create dummy main.rs to build dependencies (cache layer optimization)
RUN mkdir src && \
    echo "fn main() {}" > src/main.rs && \
    cargo build --release --target x86_64-unknown-linux-musl && \
    rm -rf src

# Copy actual source code
COPY src ./src
COPY config ./config

# Touch main.rs to invalidate the dummy build cache
RUN touch src/main.rs

# Build the release binary with static linking
# RUSTFLAGS="-C target-feature=+crt-static" ensures fully static binary
ENV RUSTFLAGS="-C target-feature=+crt-static"
RUN cargo build --release --target x86_64-unknown-linux-musl

# Verify it's statically linked
RUN file target/x86_64-unknown-linux-musl/release/service && \
    ldd target/x86_64-unknown-linux-musl/release/service 2>&1 | grep -q "not a dynamic executable" || \
    (echo "ERROR: Binary is not statically linked!" && exit 1)

# ==============================================================================
# Stage 2: Runtime (Minimal Alpine)
# ==============================================================================
FROM alpine:3.23 AS runtime

# Install CA certificates for TLS connections (Redis TLS, OTLP, etc.)
RUN apk add --no-cache ca-certificates tzdata && \
    adduser -D -u 10001 appuser

WORKDIR /app

# Copy the statically-linked binary
COPY --from=builder /app/target/x86_64-unknown-linux-musl/release/service ./service

# Copy default config (can be overridden via env vars in K8s)
COPY --from=builder /app/config ./config

# Set ownership
RUN chown -R appuser:appuser /app

# Switch to non-root user
USER appuser

# Expose the default port
EXPOSE 8080

# Set production environment
ENV APP_ENV=production

# Health check (Docker native, not used in K8s but useful for local testing)
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8080/health/live || exit 1

ENTRYPOINT ["/app/service"]
