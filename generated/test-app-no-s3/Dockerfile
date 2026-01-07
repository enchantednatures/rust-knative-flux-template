# ==============================================================================
# Stage 1: Chef - Prepare dependency recipe
# ==============================================================================
FROM rust:1.92-alpine AS chef
RUN apk add --no-cache musl-dev openssl-dev pkgconfig curl

# Install cargo-chef
RUN cargo install cargo-chef

WORKDIR /app

# Prepare the recipe (analyzes dependencies without building)
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

# ==============================================================================
# Stage 2: Build dependencies using chef recipe
# ==============================================================================
FROM rust:1.92-alpine AS builder
RUN apk add --no-cache \
    musl-dev \
    openssl-dev \
    openssl-libs-static \
    pkgconfig \
    curl

# Install cargo-chef and musl target
RUN cargo install cargo-chef && \
    rustup target add x86_64-unknown-linux-musl

WORKDIR /app

# Copy the recipe from chef stage
COPY --from=chef /app/recipe.json recipe.json

# Copy local crate dependencies (required for path dependencies)
COPY crates ./crates

# Build dependencies using the recipe (cached layer)
RUN cargo chef cook --release --target x86_64-unknown-linux-musl --recipe-path recipe.json

# Copy source code and build the application
COPY . .
RUN cargo build --release --target x86_64-unknown-linux-musl

# ==============================================================================
# Stage 3: Runtime (Minimal Alpine)
# ==============================================================================
FROM alpine:3.23 AS runtime

# Install CA certificates for TLS connections (Redis TLS, OTLP, etc.)
RUN apk add --no-cache ca-certificates tzdata && \
    adduser -D -u 10001 appuser

WORKDIR /app

# Copy the statically-linked binary
COPY --from=builder /app/target/x86_64-unknown-linux-musl/release/test_app_no_s3 ./test_app_no_s3

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

ENTRYPOINT ["./test_app_no_s3"]