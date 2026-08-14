# ==============================================================================
# Stage 1: Chef - Prepare dependency recipe
# ==============================================================================
# ARG for selecting base image tag (defaults to version, but 'release' preferred for releases)
# Note: If rust:release doesn't exist, the default version tag is used
# The release workflow passes RUST_BASE_IMAGE_TAG=release for production builds
ARG RUST_BASE_IMAGE_TAG=1.97-slim

FROM rust:${RUST_BASE_IMAGE_TAG} AS chef
RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install cargo-chef
RUN cargo install cargo-chef

WORKDIR /app

# Prepare the recipe (analyzes dependencies without building)
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

# ==============================================================================
# Stage 2: Build dependencies using chef recipe
# ==============================================================================
ARG RUST_BASE_IMAGE_TAG=1.97-slim

FROM rust:${RUST_BASE_IMAGE_TAG} AS builder
RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    curl \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install cargo-chef
RUN cargo install cargo-chef

WORKDIR /app

# Copy the recipe from chef stage
COPY --from=chef /app/recipe.json recipe.json

# Copy local crate dependencies (required for path dependencies)
COPY crates ./crates

# Build dependencies using the recipe (cached layer)
RUN cargo chef cook --release --recipe-path recipe.json

# Copy source code and build the application
COPY . .
RUN cargo build --release

# ==============================================================================
# Stage 3: Runtime (Debian Slim)
# ==============================================================================
FROM debian:bookworm-slim AS runtime

# Install CA certificates for TLS connections (Redis TLS, OTLP, etc.)
RUN apt-get update && apt-get install -y \
    ca-certificates \
    tzdata \
    && rm -rf /var/lib/apt/lists/* && \
    useradd -m -u 10001 appuser

WORKDIR /app

# Copy the binary
COPY --from=builder /app/target/release/{{ crate_name }} ./{{ crate_name }}

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

ENTRYPOINT ["./{{ crate_name }}"]