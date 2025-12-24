#!/bin/bash
# Script to generate reference implementations for E2E testing
# This should be run once and committed to the repository

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Generating reference implementations..."
echo "Repository root: $REPO_DIR"

cd /tmp

# Generate with-s3 scenario (with image updates enabled)
echo "Generating with-s3..."
cargo generate --path "$REPO_DIR" \
  --name example-app-with-s3 \
  --define include_s3=true \
  --define enable_image_updates=false \
  --define target_namespace=default \
  --define github_org=enchantednatures \
  --define github_repo=rust-knative-flux-template \
  --define default_branch=main \
  --define image_registry=ghcr.io \
  --silent

# Generate no-s3 scenario (without image updates)
echo "Generating no-s3..."
cargo generate --path "$REPO_DIR" \
  --name example-app-no-s3 \
  --define include_s3=false \
  --define enable_image_updates=false \
  --define target_namespace=default \
  --define github_org=enchantednatures \
  --define github_repo=rust-knative-flux-template \
  --define default_branch=main \
  --define image_registry=ghcr.io \
  --silent

# Move to examples directory
echo "Moving generated projects to examples/"
rm -rf "$REPO_DIR/examples"
mkdir -p "$REPO_DIR/examples"
mv /tmp/example-app-with-s3 "$REPO_DIR/examples/with-s3"
mv /tmp/example-app-no-s3 "$REPO_DIR/examples/no-s3"

# Verify directory structure
if [ ! -f "$REPO_DIR/examples/with-s3/Cargo.toml" ]; then
    echo "❌ Error: examples/with-s3/Cargo.toml not found"
    echo "   Expected location: $REPO_DIR/examples/with-s3/Cargo.toml"
    exit 1
fi

if [ ! -f "$REPO_DIR/examples/no-s3/Cargo.toml" ]; then
    echo "❌ Error: examples/no-s3/Cargo.toml not found"
    echo "   Expected location: $REPO_DIR/examples/no-s3/Cargo.toml"
    exit 1
fi

echo "✓ Reference implementations generated successfully!"
echo ""
echo "Generated examples:"
echo "  - $REPO_DIR/examples/with-s3"
echo "  - $REPO_DIR/examples/no-s3"
echo ""
echo "Next steps:"
echo "  1. Review the generated files with 'git diff'"
echo "  2. Commit the examples/ directory if changes look correct"
