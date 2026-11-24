# Services

The first service in this project is the root package (`src/`, `Cargo.toml`).
Additional services live in this directory as self-contained crates (for
example `services/orders/`) and are registered as explicit Cargo workspace
members.

Generate a new service from the repository root:

```bash
make add-service
```

or run the underlying helper directly:

```bash
scripts/add-service.sh --name orders --workload knative
```

Each generated service carries its own `deploy/` subtree and is registered in
the environment overlays by the helper. The root `Cargo.toml` intentionally
lists only `crates/*` as a glob; the helper appends `services/<name>` entries
so an empty `services/` directory never breaks the workspace.
