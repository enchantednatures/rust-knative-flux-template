#!/bin/bash
set -euo pipefail

SCENARIO="${1}"
INCLUDE_S3="${2}"

echo "Installing cargo-generate..."
cargo install cargo-generate --locked

TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

echo "Generating template: ${SCENARIO}..."
cargo generate \
  --path "$OLDPWD" \
  --name "generated-${SCENARIO}" \
  --define "include_s3=${INCLUDE_S3}" \
  --silent

GENERATED_DIR="${TEMP_DIR}/generated-${SCENARIO}"
REFERENCE_DIR="${OLDPWD}/examples/${SCENARIO}"

if [ ! -d "$GENERATED_DIR" ]; then
  echo "ERROR: Template generation failed - directory not created"
  exit 1
fi

echo "Verifying generated files exist..."
test -f "${GENERATED_DIR}/Cargo.toml" || { echo "ERROR: Cargo.toml missing"; exit 1; }
test -f "${GENERATED_DIR}/Dockerfile" || { echo "ERROR: Dockerfile missing"; exit 1; }
test -d "${GENERATED_DIR}/deploy" || { echo "ERROR: deploy/ missing"; exit 1; }

if [ "$INCLUDE_S3" = "true" ]; then
  grep -q "opendal" "${GENERATED_DIR}/Cargo.toml" || {
    echo "ERROR: opendal dependency missing in S3 scenario"
    exit 1
  }
else
  ! grep -q "opendal" "${GENERATED_DIR}/Cargo.toml" || {
    echo "ERROR: opendal dependency present in non-S3 scenario"
    exit 1
  }
fi

echo "Comparing against reference implementation..."

# Normalize directories for comparison
normalize_file() {
  # Remove Cargo.lock (we ignore this)
  find "$1" -name "Cargo.lock" -delete
  # Remove .git directories
  find "$1" -name ".git" -type d -exec rm -rf {} + 2>/dev/null || true
}

normalize_file "$GENERATED_DIR"
normalize_file "$REFERENCE_DIR"

# Compare directories
DIFF_OUTPUT=$(diff -rq \
  --exclude=".git" \
  --exclude="target" \
  --exclude="Cargo.lock" \
  "${GENERATED_DIR}" "${REFERENCE_DIR}" 2>&1 || true)

if [ -n "$DIFF_OUTPUT" ]; then
  echo "ERROR: Generated template differs from reference implementation!"
  echo ""
  echo "Differences found:"
  echo "$DIFF_OUTPUT"
  echo ""
  echo "Detailed diff:"
  diff -ru \
    --exclude=".git" \
    --exclude="target" \
    --exclude="Cargo.lock" \
    "${GENERATED_DIR}" "${REFERENCE_DIR}" || true
  echo ""
  echo "This means the examples/ directory is out of sync with the template."
  echo "Please regenerate examples by running:"
  echo "  cargo generate --path . --name ${SCENARIO} --define include_s3=${INCLUDE_S3}"
  echo "  rm -rf examples/${SCENARIO}"
  echo "  mv ${SCENARIO} examples/"
  exit 1
fi

echo "✓ Template generation verified - output matches reference"

# Cleanup
cd "$OLDPWD"
rm -rf "$TEMP_DIR"
