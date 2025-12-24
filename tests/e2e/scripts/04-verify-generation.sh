#!/bin/bash
set -euo pipefail

SCENARIO="${1}"
INCLUDE_S3="${2}"

echo "Installing cargo-generate..."
cargo install cargo-generate --locked

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# Create a persistent directory for the generated template (not temp!)
GENERATED_BASE="/tmp/e2e-generated"
mkdir -p "$GENERATED_BASE"
GENERATED_DIR="${GENERATED_BASE}/example-app-${SCENARIO}"

# Remove any previous generation
rm -rf "$GENERATED_DIR"

cd "$GENERATED_BASE"

echo "Generating template: ${SCENARIO}..."

# Extract org and repo from GITHUB_REPOSITORY (format: owner/repo)
if [ -n "${GITHUB_REPOSITORY:-}" ]; then
  GH_ORG="${GITHUB_REPOSITORY%%/*}"
  GH_REPO="${GITHUB_REPOSITORY##*/}"
else
  # Local development fallback
  GH_ORG="your-org"
  GH_REPO="rust-service"
fi

echo "  Using gh_org=${GH_ORG}, gh_repo=${GH_REPO}"

# Generate with actual repository parameters for E2E testing
cargo generate \
  --path "$PROJECT_ROOT" \
  --name "example-app-${SCENARIO}" \
  --define "include_s3=${INCLUDE_S3}" \
  --define "gh_org=${GH_ORG}" \
  --define "gh_repo=${GH_REPO}" \
  --silent

REFERENCE_DIR="${PROJECT_ROOT}/examples/${SCENARIO}"

# Save the generated directory path for later steps
echo "$GENERATED_DIR" > "${SCRIPT_DIR}/.generated-dir-${SCENARIO}"

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
echo "✓ Generated template saved at: ${GENERATED_DIR}"
echo ""
echo "Generated template will be used for E2E deployment with:"
echo "  - gh_org: ${GH_ORG}"
echo "  - gh_repo: ${GH_REPO}"

# Return to original directory (don't cleanup - we need generated template!)
cd "$PROJECT_ROOT"
