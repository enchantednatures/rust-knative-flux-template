# CloudEvents crates (Kellnr)

The `axum-cloudevents` dependency is **not vendored** in this project. It is
published to the private [Kellnr](https://kellnr.io/) registry and resolved from
there at build time.

## Registry configuration

The generated project contains `.cargo/config.toml`:

```toml
[registries.kellnr]
index = "sparse+https://crates.enchantednatures.com/api/v1/crates/"
credential-provider = ["cargo:token"]
```

The index is configured with the `kellnr_index` template value. No token is
committed.

## Authentication

Kellnr requires authentication for index and crate downloads. Authenticate once
per machine:

```bash
cargo login --registry kellnr
```

Or provide the token through the environment:

```bash
export CARGO_REGISTRIES_KELLNR_TOKEN=...
```

The token is stored in `$CARGO_HOME/credentials.toml` by `cargo login`. Do not
commit `.cargo/credentials.toml`; it is ignored by git.

## CI

The generated `.github/workflows/ci.yaml` and `release.yaml.liquid` read the
token from the `KELLNR_TOKEN` repository secret. Add it before the first
pipeline run:

```bash
gh secret set KELLNR_TOKEN --repo <org>/<repo>
```

The value can be piped from stdin to keep it out of shell history:

```bash
printf '%s' "$KELLNR_TOKEN" | gh secret set KELLNR_TOKEN --repo <org>/<repo>
```

If the secret is missing, the pipeline fails early with a clear error. Fork pull
requests do not receive repository secrets; they will need a maintainer-run
workflow or a public read token.

## Docker builds

The Dockerfile reads the token as a BuildKit secret and never writes it into an
image layer:

```bash
docker build \
  --secret id=cargo_token,env=CARGO_REGISTRIES_KELLNR_TOKEN \
  -t my-service:latest .
```

`make dev-restart` and `scripts/dev/build-and-deploy.sh` resolve the token from
`CARGO_REGISTRIES_KELLNR_TOKEN` or the `[registries.kellnr]` entry in
`$CARGO_HOME/{credentials,config}.toml` and pass the secret automatically.

## Source and publishing

The crate source lives in
[`enchantednatures/axum-cloudevents`](https://github.com/enchantednatures/axum-cloudevents):

- `axum-cloudevents` — extractor, metadata, headers, and the re-exported derive
- `axum-cloudevents-macros` — the `CloudEventTagged` derive

Publishing is handled by that repository's `crates-v*` workflow, which publishes
the macros crate first and then the main crate. The workflow requires the
`KELLNR_PUBLISH_TOKEN` secret.

To consume a new release here:

1. Publish the new version in the crate repository.
2. Update the dependency range in `Cargo.toml` if the minor version changed:

   ```toml
   axum-cloudevents = { version = "0.2", registry = "kellnr" }
   ```

3. Run `cargo update -p axum-cloudevents` in the generated project and commit
   the updated `Cargo.lock`.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `registry kellnr requires authentication` | No token available | `cargo login --registry kellnr` or set `CARGO_REGISTRIES_KELLNR_TOKEN` |
| `no matching package named axum-cloudevents` | Wrong index or version | Check `.cargo/config.toml` and the published version |
| Docker build fails with an auth error | BuildKit secret not passed | Use `--secret id=cargo_token,env=CARGO_REGISTRIES_KELLNR_TOKEN` |
| CI fails only on fork PRs | Secrets are not exposed to forks | Run the workflow from a branch in the main repository or provide a read-only public token |

## Trademark

`axum-cloudevents` is a descriptive third-party crate name. It is not affiliated
with or endorsed by the Axum project.
