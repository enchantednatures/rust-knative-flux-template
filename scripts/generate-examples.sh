#!/bin/bash
# Script to generate reference implementations for E2E testing
# This should be run once and committed to the repository

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Generating reference implementations..."

cd /tmp

# Generate with-s3 scenario
echo "Generating with-s3..."
cargo-generate --path "$REPO_DIR" \
  --name with-s3 \
  --define include_s3=true \
  --silent

# Generate no-s3 scenario
echo "Generating no-s3..."
cargo-generate --path "$REPO_DIR" \
  --name no-s3 \
  --define include_s3=false \
  --silent

# Move to examples directory
echo "Moving generated projects to examples/"
rm -rf "$REPO_DIR/examples"
mkdir -p "$REPO_DIR/examples"
mv /tmp/with-s3 "$REPO_DIR/examples/"
mv /tmp/no-s3 "$REPO_DIR/examples/"

# Remove Cargo.lock from examples (reproducibility)
rm -f "$REPO_DIR/examples/with-s3/Cargo.lock"
rm -f "$REPO_DIR/examples/no-s3/Cargo.lock"

# Verify compilation
echo "Verifying compilation..."
cd "$REPO_DIR/examples/with-s3"
cargo check

cd "$REPO_DIR/examples/no-s3"
cargo check

echo "✓ Reference implementations generated successfully!"
echo ""
echo "Next steps:"
echo "  1. Commit the examples/ directory"
echo "  2. Run CI tests to verify everything works"
