# Contributing

Thanks for taking the time to contribute.

This repository is a `cargo-generate` template: it ships a Rust service plus the
Kubernetes/Flux manifests that deploy it. Changes must keep **both** the
template repository and freshly generated projects green.

## Getting started

```bash
git clone https://github.com/enchantednatures/rust-knative-flux-template.git
cd rust-knative-flux-template

# Toolchain is pinned in rust-toolchain.toml (Rust 1.92+)
rustup show

# axum-cloudevents resolves from the private Kellnr registry
cargo login --registry kellnr   # or export CARGO_REGISTRIES_KELLNR_TOKEN

# Generate a project with every feature enabled and build it
cargo generate --path . --name scratch --template-values-file ci/template-values-full.toml --allow-commands
cd scratch && cargo fmt --all -- --check && cargo clippy --all-targets --all-features -- -D warnings && cargo test
```

Detailed project-level workflow: [`docs/CONTRIBUTING.md`](./docs/CONTRIBUTING.md).
Local environment: [`docs/DEVELOPMENT.md`](./docs/DEVELOPMENT.md).
Test strategy: [`docs/TESTING.md`](./docs/TESTING.md).
CloudEvents crates: [`docs/CRATES.md`](./docs/CRATES.md).

The `axum-cloudevents` crates are no longer vendored. Changes to them belong in
[`enchantednatures/axum-cloudevents`](https://github.com/enchantednatures/axum-cloudevents);
this template consumes the version published to Kellnr. The template CI requires
the `KELLNR_TOKEN` repository secret.

## What CI checks

Every pull request runs:

| Workflow | What it proves |
|----------|----------------|
| `Template Generate & Validate` | 12 generation scenarios format, lint, build; the all-features project also builds in release mode, builds a Docker image, renders the chart/overlays, and runs the live-infra integration suites |
| `Naming Convention Tests` | kebab-case, snake_case, and single-word project names normalize correctly across Cargo, the chart, Knative, and Docker |
| `E2E Tests` | Live Kind + Knative deployment per scenario (S3, Flagger, Postgres, cron, GHA runner) |

Run the closest checks locally before pushing:

```bash
cd <generated-project>
cargo fmt --all -- --check
cargo clippy --all-targets --all-features -- -D warnings
cargo build --release --all-features
cargo test --all-features
```

## Pull requests

1. Branch from `main`; keep the change focused.
2. Use Conventional Commits (`feat:`, `fix:`, `docs:`, `test:`, `chore:`).
3. Update documentation and the [changelog](./CHANGELOG.md) when behaviour
   changes.
4. Add or update tests. Prefer a CI-enforced test over a manual script.
5. Fill in the pull-request template, including the verification commands you
   ran and their output.

## Adding a feature flag

1. Add the prompt to `cargo-generate.toml` with a `false` default unless it is
   safe to enable everywhere.
2. Add the conditional `ignore` entries for files that must not ship when the
   flag is off.
3. Wire the manifests, source files, docs, and README section.
4. Add a row to the `generate-and-validate` matrix and, if the feature needs a
   cluster, a scenario to `template-e2e-test.yaml`.
5. Assert both the "on" and "off" shapes in the workflow steps.

## Reporting bugs and requesting features

Use the issue templates. Include:

- the template version (`[template] version` in `cargo-generate.toml`, or the
  `v*` tag you generated from),
- the answers you gave to the generation prompts,
- the command that failed and its output.

Security issues must follow [`SECURITY.md`](./SECURITY.md) instead of the public
issue tracker.

## Code of conduct

Participation is governed by [`CODE_OF_CONDUCT.md`](./CODE_OF_CONDUCT.md).

## License

Contributions are accepted under the MIT license; see [`LICENSE`](./LICENSE).
