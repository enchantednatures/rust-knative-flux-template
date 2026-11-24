# ==============================================================================
# Per-service build selection
# ==============================================================================
# The same Dockerfile builds the first service (the workspace root package) and
# any added service under services/. Defaults preserve the first service; the
# release workflow / dev scripts pass --build-arg for added services:
#   --build-arg SERVICE_DIR=services/<svc>
#   --build-arg SERVICE_PKG=<cargo package name>
#   --build-arg SERVICE_BIN=<binary name>
ARG SERVICE_DIR=.
ARG SERVICE_PKG={{ crate_name }}
ARG SERVICE_BIN={{ crate_name }}

# ==============================================================================
# Stage 1: Chef - Prepare dependency recipe
# ==============================================================================
# ARG for selecting the base image tag. This default is the single source of
# truth (renovate keeps rust-toolchain.toml and the Dockerfile in sync); the
# release workflow builds without overriding it.
ARG RUST_BASE_IMAGE_TAG=1.100-slim

FROM rust:${RUST_BASE_IMAGE_TAG} AS chef
# Kafka native build packages are unconditional: an added service may enable
# rdkafka even when the platform was generated with feature_kafka=false, so the
# platform Liquid flag must not gate the builder toolchain.
RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    curl \
    cmake \
    libcurl4-openssl-dev \
    libsasl2-dev \
    libzstd-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Install cargo-chef
RUN cargo install cargo-chef

WORKDIR /app

# Prepare the recipe (analyzes the whole workspace without building). The
# private Kellnr index needs the token even for metadata resolution.
COPY . .
RUN --mount=type=secret,id=cargo_token,env=CARGO_REGISTRIES_KELLNR_TOKEN \
    cargo chef prepare --recipe-path recipe.json

# ==============================================================================
# Stage 2: Build dependencies using chef recipe
# ==============================================================================
ARG RUST_BASE_IMAGE_TAG=1.100-slim

FROM rust:${RUST_BASE_IMAGE_TAG} AS builder
ARG SERVICE_PKG
ARG SERVICE_BIN

# Kafka native build packages are unconditional (see the chef stage).
RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    curl \
    build-essential \
    cmake \
    libcurl4-openssl-dev \
    libsasl2-dev \
    libzstd-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Install cargo-chef
RUN cargo install cargo-chef

WORKDIR /app

# Copy the recipe and the resolved lock from the chef stage.
COPY --from=chef /app/recipe.json recipe.json
COPY --from=chef /app/Cargo.lock Cargo.lock

# Registry configuration (index only; no credentials). The Kellnr token is
# supplied as a BuildKit secret so it never lands in an image layer:
#   docker build --secret id=cargo_token,env=CARGO_REGISTRIES_KELLNR_TOKEN .
COPY .cargo ./.cargo

# Copy the whole workspace layout the recipe resolves: the shared core crate,
# added services (empty-safe directory copy) and the root manifest. Only changes
# here invalidate the dependency cook layer.
COPY crates/service-core ./crates/service-core
COPY services ./services
COPY Cargo.toml ./

# Build dependencies using the recipe (cached layer)
RUN --mount=type=secret,id=cargo_token,env=CARGO_REGISTRIES_KELLNR_TOKEN \
    cargo chef cook --release --recipe-path recipe.json

# Copy source code and build the selected service. Package selection is
# required: a non-virtual workspace root builds only the root package by default.
COPY . .
RUN --mount=type=secret,id=cargo_token,env=CARGO_REGISTRIES_KELLNR_TOKEN \
    cargo build --release -p "${SERVICE_PKG}" --bin "${SERVICE_BIN}"

# ==============================================================================
# Stage 3: Runtime (Debian Slim — must match the builder's Debian release for
# the linked glibc; rust:slim tracks the current stable, so this tracks trixie)
# ==============================================================================
FROM debian:trixie-slim AS runtime
ARG SERVICE_DIR
ARG SERVICE_BIN

# Install CA certificates for TLS connections (Redis TLS, OTLP, etc.) and curl,
# which the Docker HEALTHCHECK below uses (slim images ship neither curl nor wget)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    tzdata \
    && rm -rf /var/lib/apt/lists/* && \
    useradd -m -u 10001 appuser

WORKDIR /app

# Copy the selected service's binary to a fixed entrypoint path so added-service
# images never execute the first crate's binary.
COPY --from=builder /app/target/release/${SERVICE_BIN} ./service

# Copy the selected service's default config (overridable via env vars in K8s)
COPY --from=builder /app/${SERVICE_DIR}/config ./config

# Set ownership
RUN chown -R appuser:appuser /app

# Switch to non-root user
USER appuser

# Expose the default port
EXPOSE 8080

# Set production environment
ENV APP_ENV=production

# Health check (Docker native, not used in K8s but useful for local testing).
# Uses curl, installed in the runtime stage above; Knative probes use HTTP and
# ignore this instruction entirely.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -fsS http://localhost:8080/health/live || exit 1

ENTRYPOINT ["/app/service"]
