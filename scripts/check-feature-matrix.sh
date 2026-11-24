#!/usr/bin/env bash
set -euo pipefail

# Script: check-feature-matrix.sh
# Purpose: Prove that every `service-core` feature combination compiles in
#          isolation and that the application crate still compiles with the
#          generated feature set.
# Usage:   ./scripts/check-feature-matrix.sh
#
# This is a fast `cargo check` matrix (no codegen/linking), safe to run on
# every CI build. It fails on the first broken combination. The generated
# service-core always declares the optional `kafka` feature, so
# `--all-features` compiles rdkafka even when the project was generated with
# feature_kafka=false — CI must install the native build packages
# (cmake, libcurl, libsasl2, zstd, zlib) unconditionally.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

if [[ ! -f Cargo.toml ]]; then
  echo "error: no Cargo.toml at $REPO_ROOT (run from a generated project)" >&2
  exit 1
fi

if ! cargo metadata --no-deps --format-version 1 >/dev/null 2>&1; then
  echo "error: cargo metadata failed at $REPO_ROOT" >&2
  exit 1
fi

run() {
  echo "==> cargo check $*"
  cargo check "$@"
}

# Feature isolation: each optional dependency must compile on its own, then
# all of them together.
run -p service-core --no-default-features
run -p service-core --no-default-features --features postgres
run -p service-core --no-default-features --features s3
run -p service-core --no-default-features --features kafka
run -p service-core --all-features

# The application crate with the feature set baked into its generated
# Cargo.toml (service-core dependency features). Resolve the root package
# from the manifest rather than assuming a crate name.
APP_PKG="$(
  awk '
    /^\[package\]/ { in_pkg = 1; next }
    /^\[/ { in_pkg = 0 }
    in_pkg && /^name[[:space:]]*=/ {
      sub(/^name[[:space:]]*=[[:space:]]*"/, "")
      sub(/".*$/, "")
      print
      exit
    }
  ' Cargo.toml
)"

if [[ -z "$APP_PKG" ]]; then
  echo "error: could not resolve the root package name from Cargo.toml" >&2
  exit 1
fi

run -p "$APP_PKG"

echo "feature matrix: OK"
