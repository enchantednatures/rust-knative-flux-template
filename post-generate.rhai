// Post-generation hook: automatically format and lint generated code
// This runs after template expansion but before final output is moved to destination

// Step 1: Run clippy --fix to automatically fix linting issues
// --allow-dirty: Allow fixes even with uncommitted changes
// --allow-staged: Allow fixes on staged files
system::command("cargo", ["clippy", "--fix", "--allow-dirty", "--allow-staged"]);

// Step 2: Run cargo fmt to format all generated code
// --all: Format all packages in workspace
system::command("cargo", ["fmt", "--all"]);
