// Post-generation hook: format the generated project.
//
// Runs after template expansion while the output still lives in
// cargo-generate's working copy (cargo-generate >= 0.23). Every command is
// wrapped in try/catch: failures are printed as warnings but never abort
// generation.
//
// Linting is intentionally NOT run here: a cold `cargo clippy` inside the
// temporary working copy compiles the whole crate graph and can block
// generation for many minutes. CI enforces clippy explicitly afterwards.
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

// Step 1: Format all generated code (non-blocking)
print("🔧 Running cargo fmt...");
try {
    system::command("cargo", ["fmt", "--all"]);
} catch (err) {
    warnings += 1;
    print("⚠️  cargo fmt failed (non-blocking): " + err);
    print("    Fix later with: cargo fmt --all");
}

// Step 2: Remove build artifacts so they are not copied into the output.
// cargo-generate copies everything from its working copy into the final
// project directory.
try {
    file::delete("target");
} catch (err) {
    print("⚠️  Could not remove target/ (non-blocking): " + err);
}

if warnings > 0 {
    print("\n⚠️  Post-generation format finished with " + warnings + " warning(s).");
    print("    The project was generated successfully — apply the fixes above manually.");
} else {
    print("\n✅ Generated project is formatted.");
}

print("\nNext steps:");
print("  1. Review the generated code");
print("  2. Update config files with your settings");
print("  3. Run: make local-up  (to start the local dev environment)");
print("  4. Deploy to a cluster: make deploy dev  (see docs/DEPLOYMENT.md)");
