
# S3/MinIO Integration (Not Enabled)

This template was generated without S3 storage support. To add it later:

1. Update `cargo-generate.toml` to include S3 option
2. Re-generate the template with `include_s3 = true`

Or manually:
1. Add `opendal` dependency to `Cargo.toml`
2. Add `S3Config` struct to `src/config.rs`
3. Add `storage: Operator` to `AppState` in `src/state.rs`
4. Initialize operator in `src/main.rs`


