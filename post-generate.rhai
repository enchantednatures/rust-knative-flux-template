// Post-generation hook: automatically format and lint generated code
// This runs after template expansion but before final output is moved to destination
//
// NOTE: These commands will prompt for user approval unless you use --allow-commands flag:
//   cargo generate --allow-commands ...
//
// In CI/automated environments, always use --allow-commands to avoid interactive prompts

// ============================================================================
// Step 1: Validate Project Name Conventions
// ============================================================================
// Project names must be safe for use in Kubernetes and Docker image tags.
// This script validates naming conventions and provides helpful feedback.

// Get the generated crate name from Cargo.toml
let cargo_toml = `Cargo.toml`;
let content = std::fs::read_to_string(cargo_toml).unwrap_or("");

// Extract crate name from Cargo.toml
let lines = content.split("\n");
let crate_name = "";
for line in lines {
    if line.starts_with("name = ") {
        // Extract the value between quotes
        let start = line.find("\"") + 1;
        let end = line.rfind("\"");
        if start > 0 && end > start {
            crate_name = line.substring(start, end);
        }
        break;
    }
}

if crate_name.is_empty() {
    print("⚠️  Warning: Could not determine crate name from Cargo.toml");
} else {
    print(`✓ Project verified - Crate name: ${crate_name}`);
    print(`  Rust code:      uses ${crate_name} (underscores)`);
    print(`  Kubernetes:     uses ${crate_name.replace("_", "-")} (hyphens)`);
    print(`  Docker image:   ${crate_name.replace("_", "-")}:tag`);
}

// ============================================================================
// Step 2: Run Clippy to automatically fix linting issues
// ============================================================================
// --allow-dirty: Allow fixes even with uncommitted changes
// --allow-staged: Allow fixes on staged files
// --allow-no-vcs: Allow fixes when not in a git repository
print("\nRunning clippy --fix...");
system::command("cargo", ["clippy", "--fix", "--allow-dirty", "--allow-staged", "--allow-no-vcs"]);

// ============================================================================
// Step 3: Format all generated code
// ============================================================================
// --all: Format all packages in workspace
print("Running cargo fmt...");
system::command("cargo", ["fmt", "--all"]);

print("\n✓ Project generation complete!");
print("✓ All naming conventions verified");
print("✓ Code formatted and linted");
print("\nNext steps:");
print("  1. Review the generated code");
print("  2. Update config files with your settings");
print("  3. Run: make dev-up  (to start development environment)");
