## Summary

<!-- What changes, and why. Link the issue: Closes #123 -->

## Type of change

- [ ] Bug fix (`fix:`)
- [ ] New feature (`feat:`)
- [ ] Documentation (`docs:`)
- [ ] Refactor / chore
- [ ] CI or test change (`test:`)

## Affected generation path

<!-- Which prompts are involved? e.g. all-features, feature_s3 only, bare -->

## Verification

<!-- Paste the commands you ran and their result. A claim without output does
     not count. -->

```bash
cargo generate --path . --name scratch --template-values-file ci/template-values-full.toml --allow-commands
cd scratch
cargo fmt --all -- --check
cargo clippy --all-targets --all-features -- -D warnings
cargo build --release --all-features
cargo test --all-features
```

- [ ] Generated with all features and built locally
- [ ] `kubectl kustomize deploy/overlays/{dev,staging,prod}` renders
- [ ] `helm template` renders the chart with the HelmRelease values
- [ ] Added/updated the generation matrix or E2E scenario when a feature changed
- [ ] Updated `CHANGELOG.md` for user-facing changes

## Notes for reviewers

<!-- Anything tricky: migration notes, follow-ups, known gaps. -->
