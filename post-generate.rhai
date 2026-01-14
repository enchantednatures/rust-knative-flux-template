// Post-generation hook: automatically format and lint generated code
// This runs after template expansion but before final output is moved to destination
//
// NOTE: These commands will prompt for user approval unless you use --allow-commands flag:
//   cargo generate --allow-commands ...
//
// In CI/automated environments, always use --allow-commands to avoid interactive prompts

print("\n╔════════════════════════════════════════════════════════╗");
print("║          Project Generation Complete! ✓               ║");
print("╚════════════════════════════════════════════════════════╝\n");

print("Naming Convention Info:");
print("  ✓ Rust code uses underscores in crate names (Cargo.toml)");
print("  ✓ Kubernetes services use hyphens in resource names");
print("  ✓ Docker images use hyphens in tags");
print("  ✓ All names are automatically normalized during generation\n");

// ============================================================================
// Step 1: Run Clippy to automatically fix linting issues
// ============================================================================
// NOTE: Clippy is disabled during template generation because it builds the
// project and creates a target/ directory with binary files that contain
// {{ }} patterns, causing cargo-generate validation to fail.
// This will be run manually after generation.
// print("🔧 Running clippy --fix...");
// system::command("cargo", ["clippy", "--fix", "--allow-dirty", "--allow-staged", "--allow-no-vcs"]);

// ============================================================================
// Step 2: Format all generated code
// ============================================================================
// --all: Format all packages in workspace
print("🔧 Running cargo fmt...");
system::command("cargo", ["fmt", "--all"]);

print("\n✅ Project generation complete!\n");
print("Next steps:");
print("  1. Review the generated code");
print("  2. Update config files with your settings");
print("  3. Run: make dev-up  (to start development environment)");
