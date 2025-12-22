# Reference Implementations

This directory contains fully-generated reference implementations for E2E testing.

- **`with-s3/`** - Generated with `include_s3=true` (includes S3/MinIO support)
- **`no-s3/`** - Generated with `include_s3=false` (basic service only)

## Generating Examples

To regenerate these examples after template changes:

```bash
cd /path/to/rust-knative-flux-template

# Option 1: Use helper script (recommended)
scripts/generate-examples.sh

# Option 2: Manual generation
cd /tmp
cargo generate --path /path/to/rust-knative-flux-template --name with-s3 --define include_s3=true
cargo generate --path /path/to/rust-knative-flux-template --name no-s3 --define include_s3=false

# Move to examples
rm -rf /path/to/rust-knative-flux-template/examples
mkdir /path/to/rust-knative-flux-template/examples
mv with-s3 /path/to/rust-knative-flux-template/examples/
mv no-s3 /path/to/rust-knative-flux-template/examples/

# Cleanup and verify
cd /path/to/rust-knative-flux-template/examples
rm with-s3/Cargo.lock no-s3/Cargo.lock
cd with-s3 && cargo check && cd ../no-s3 && cargo check

# Commit
cd /path/to/rust-knative-flux-template
git add examples/
git commit -m "Update reference implementations"
```

## Purpose

These examples serve dual purposes:

1. **Living Documentation** - Users can explore fully-working, generated code
2. **E2E Testing Baseline** - CI verifies `cargo generate` produces identical output

## Note

`Cargo.lock` files are NOT committed. They're regenerated during dependency resolution.
