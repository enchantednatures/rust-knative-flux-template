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

// ── Generation inputs snapshot ────────────────────────────────────────────
//
// Records every resolved placeholder in `.cargo-generate/values.toml` so the
// project can be re-rendered later (`make template-update`, three-way merged)
// without re-answering the prompts.
//
// Invariants enforced by `scripts/check-template-values.sh` (template CI):
//   * the placeholder list below matches cargo-generate.toml exactly, in order
//   * TEMPLATE_VALUES_VERSION matches `[template] version` in cargo-generate.toml
//
// The list is explicit because cargo-generate's Rhai API exposes lookups
// (`variable::get` / `variable::is_set`) but no enumeration.

const TEMPLATE_VALUES_VERSION = "1.0.0";
const TEMPLATE_VALUES_PATH = ".cargo-generate/values.toml";

// Escapes a value for a TOML basic string. This engine only ships Rhai's
// "basic string" package (no `String::replace`), hence the manual loop.
fn template_values_escape(value) {
    let out = "";
    let i = 0;
    while i < value.len() {
        let c = value.sub_string(i, 1);
        if c == "\\" {
            out += "\\\\";
        } else if c == "\"" {
            out += "\\\"";
        } else if c == "\n" {
            out += "\\n";
        } else if c == "\r" {
            out += "\\r";
        } else if c == "\t" {
            out += "\\t";
        } else {
            out += c;
        }
        i += 1;
    }
    out
}

// BEGIN TEMPLATE VALUES PLACEHOLDERS
const TEMPLATE_VALUES_PLACEHOLDERS = [
    "project_name",
    "project_author",
    "template_repo_url",
    "template_ref",
    "kellnr_index",
    "workload_type",
    "feature_s3",
    "feature_postgres",
    "feature_kafka",
    "feature_flagger",
    "feature_gha_runner",
    "feature_cluster_smoke",
    "event_source_kafka",
    "feature_cron",
    "enable_image_updates",
    "target_namespace",
    "github_org",
    "github_repo",
    "default_branch",
    "image_registry",
    "git_auth_secret",
    "image_pull_secret",
    "custom_domain",
    "network_policy_allow_all",
    "use_default_scaling",
    "base_min_scale",
    "base_max_scale",
    "base_target",
    "base_cpu_request",
    "base_cpu_limit",
    "base_memory_request",
    "base_memory_limit",
    "dev_min_scale",
    "dev_max_scale",
    "dev_cpu_request",
    "dev_cpu_limit",
    "dev_memory_request",
    "dev_memory_limit",
    "staging_min_scale",
    "staging_max_scale",
    "staging_cpu_request",
    "staging_cpu_limit",
    "staging_memory_request",
    "staging_memory_limit",
    "prod_min_scale",
    "prod_max_scale",
    "prod_cpu_request",
    "prod_cpu_limit",
    "prod_memory_request",
    "prod_memory_limit",
    "workload_replicas",
    "workload_replicas_dev",
    "workload_replicas_staging",
    "workload_replicas_prod",
    "workload_max_unavailable",
    "workload_max_surge",
    "workload_termination_grace_period_seconds",
    "workload_prestop_sleep_seconds",
    "workload_pdb_enabled",
    "workload_pdb_min_available",
    "workload_service_type",
    "workload_service_port",
    "workload_session_affinity",
    "ingress_enabled",
    "ingress_class_name",
    "ingress_host",
    "ingress_path",
    "ingress_path_type",
    "ingress_tls_enabled",
    "ingress_tls_secret_name",
    "kafka_topic",
    "kafka_consumer_group",
    "kafka_bootstrap_servers_staging",
    "kafka_bootstrap_servers_prod",
    "kafka_managed_cluster",
    "kafka_managed_provider",
    "kafka_storage_class",
    "feature_bucket_notifications",
    "ceph_object_store_name",
    "ceph_object_store_namespace",
    "cron_schedule",
    "cron_timezone",
    "cron_payload",
    "postgres_version",
    "postgres_pooler",
    "postgres_pooler_instances_dev",
    "postgres_pooler_instances_staging",
    "postgres_pooler_instances_prod",
    "postgres_instances_dev",
    "postgres_instances_staging",
    "postgres_instances_prod",
    "postgres_storage_class",
    "backup_schedule",
    "backup_retention_dev",
    "backup_retention_staging",
    "backup_retention_prod",
    "barman_plugin_installed",
    "ceph_rgw_endpoint_dev",
    "ceph_rgw_endpoint_staging",
    "ceph_rgw_endpoint_prod",
    "ceph_bucket_storage_class",
    "kafka_broker_url",
    "kafka_event_name",
    "canary_success_rate_threshold",
    "canary_latency_threshold_ms",
    "flagger_prometheus_url_staging",
    "flagger_prometheus_url_prod",
    "flagger_operator_metrics_server",
    "gha_runner_chart_version",
    "gha_runner_image_tag",
    "gha_runner_max",
    "gha_runner_storage_class",
    "gha_runner_priority_class",
    "gha_runner_storage_size",
    "smoke_environment",
];
// END TEMPLATE VALUES PLACEHOLDERS

try {
    let lines = [
        "# Inputs used to generate this project (cargo-generate).",
        "#",
        "# `make template-update` re-renders the template with these values and",
        "# three-way merges the result into this checkout. Editing a value here",
        "# changes future regenerations only; disabling a feature does not delete",
        "# files that were generated earlier (generate fresh for structural changes).",
        "",
        "[template]",
        "version = \"" + TEMPLATE_VALUES_VERSION + "\"",
    ];
    // `--name` decides the crate name (`crate_name`), which is independent of
    // the `project_name` answer; record it so re-renders keep the same crate.
    if variable::is_set("project-name") {
        lines.push("name = \"" + template_values_escape(variable::get("project-name").to_string()) + "\"");
    }
    lines.push("");
    lines.push("[values]");
    for name in TEMPLATE_VALUES_PLACEHOLDERS {
        if variable::is_set(name) {
            let value = variable::get(name);
            let kind = type_of(value);
            if kind == "bool" {
                lines.push(name + " = " + value.to_string());
            } else if kind == "string" {
                lines.push(name + " = \"" + template_values_escape(value.to_string()) + "\"");
            }
        }
    }
    // `file::write` with an array writes one line per entry (blank lines stay).
    file::write(TEMPLATE_VALUES_PATH, lines);
    // The template ships this empty file so the directory exists for the write.
    file::delete(".cargo-generate/.gitkeep");
    print("\n📝  Recorded generation inputs in " + TEMPLATE_VALUES_PATH);
} catch (err) {
    print("\n⚠️  Could not record generation inputs (non-blocking): " + err);
    print("    Fix later with: make template-update (it needs " + TEMPLATE_VALUES_PATH + ")");
}

print("\nNext steps:");
print("  1. Review the generated code");
print("  2. Update config files with your settings");
print("  3. Run: make local-up  (to start the local dev environment)");
print("  4. Deploy to a cluster: make deploy dev  (see docs/DEPLOYMENT.md)");
