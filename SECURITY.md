# Security Policy

## Supported versions

This template is released with `v*` tags. Security fixes land on the latest
minor release and on `main`.

| Version | Supported |
|---------|-----------|
| 1.x (latest tag) | ✅ |
| `main` (unreleased) | ✅ |
| < 1.0 | ❌ |

Generated projects pin their own dependency versions; see `Cargo.lock`,
`renovate.json`, and `docs/UPGRADING.md` for the update path.

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Report privately through GitHub's [private vulnerability
reporting](https://github.com/enchantednatures/rust-knative-flux-template/security/advisories/new)
(Security → Advisories → "Report a vulnerability").

Please include:

- the affected template version, tag, or commit,
- the generation prompts used (feature flags change the attack surface),
- reproduction steps or a proof of concept,
- the impact you believe it has.

### What to expect

| Stage | Target |
|-------|--------|
| Acknowledgement | within 3 business days |
| Initial assessment and severity | within 7 days |
| Fix or mitigation plan | within 30 days for high/critical |

We will coordinate disclosure with you and credit you in the advisory and
release notes unless you ask us not to.

## Scope

In scope:

- the template repository (generation logic, manifests, scripts, CI workflows),
- the vendored `crates/axum-cloudevents` and `crates/axum-cloudevents-macros`,
- the Dockerfile and shipped runtime configuration.

Out of scope:

- vulnerabilities in a *deployed* project that a user introduced by changing the
  template or its configuration,
- issues that require cluster-admin access, a compromised CI runner, or a
  compromised container registry,
- findings from automated scanners with no demonstrated impact.

## Hardening guidance

`docs/SECURITY.md` is the hardening guide for generated projects: container and
Kubernetes security, secret management, network policy, supply chain, and the
pre-release checklist. Read it before deploying to production.

The generated workflows include Trivy image scanning; enable GitHub code
scanning if your plan supports SARIF upload.
