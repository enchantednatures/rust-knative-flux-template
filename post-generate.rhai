// Post-generation hook: automatically format and lint generated code
// This runs after template expansion but before final output is moved to destination
//
// NOTE: These commands will prompt for user approval unless you use --allow-commands flag:
//   cargo generate --allow-commands ...
//
// In CI/automated environments, always use --allow-commands to avoid interactive prompts

// Step 1: Run clippy --fix to automatically fix linting issues
// --allow-dirty: Allow fixes even with uncommitted changes
// --allow-staged: Allow fixes on staged files
// --allow-no-vcs: Allow fixes when not in a git repository
system::command("cargo", ["clippy", "--fix", "--allow-dirty", "--allow-staged", "--allow-no-vcs"]);

// Step 2: Run cargo fmt to format all generated code
// --all: Format all packages in workspace
system::command("cargo", ["fmt", "--all"]);
