// Post-generation hook: format and lint the generated project.
//
// Runs after template expansion while the output still lives in
// cargo-generate's working copy (cargo-generate >= 0.23). Every command is
// wrapped in try/catch: failures are printed as warnings but never abort
// generation (CI validates fmt/clippy explicitly afterwards).
//
// Commands require `cargo generate --allow-commands` — mandatory when
// combined with `--silent`, since silent mode cannot prompt for approval.

print("\n╔════════════════════════════════════════════════════════╗");
print("║          Project Generation Complete! ✓               ║");
print("╚════════════════════════════════════════════════════════╝\n");

print("Naming Convention Info:");
print("  ✓ Rust code uses underscores in crate names (Cargo.toml)");
print("  ✓ Kubernetes services use hyphens in resource names");
print("  ✓ Docker images use hyphens in tags");
print("  ✓ All names are automatically normalized during generation\n");

let warnings = 0;

// Step 1: Auto-fix lint issues (non-blocking)
print("🔧 Running clippy --fix...");
try {
    system::command("cargo",
        ["clippy", "--fix", "--allow-dirty", "--allow-staged", "--allow-no-vcs"]);
} catch (err) {
    warnings += 1;
    print("⚠️  clippy --fix failed (non-blocking): " + err);
    print("    Fix later with: cargo clippy --fix --allow-dirty --allow-staged --allow-no-vcs");
}

// Step 2: Format all generated code (non-blocking)
print("🔧 Running cargo fmt...");
try {
    system::command("cargo", ["fmt", "--all"]);
} catch (err) {
    warnings += 1;
    print("⚠️  cargo fmt failed (non-blocking): " + err);
    print("    Fix later with: cargo fmt --all");
}

// Step 3: Remove build artifacts so they are not copied into the output.
// clippy compiles the project, creating a target/ directory; cargo-generate
// copies everything from its working copy into the final project directory.
try {
    file::delete("target");
} catch (err) {
    print("⚠️  Could not remove target/ (non-blocking): " + err);
}

if warnings > 0 {
    print("\n⚠️  Post-generation lint/format finished with " + warnings + " warning(s).");
    print("    The project was generated successfully — apply the fixes above manually.");
} else {
    print("\n✅ Generated project is formatted and clippy-clean.");
}

print("\nNext steps:");
print("  1. Review the generated code");
print("  2. Update config files with your settings");
print("  3. Run: make dev-up  (to start development environment)");
