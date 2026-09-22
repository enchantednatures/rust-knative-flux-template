# Changelog

All notable changes to {{ project_name }} will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added (PostgreSQL feature, shipped core)

- `feature_postgres` now deploys a complete CloudNativePG stack as a Kustomize Component (`deploy/components/postgres/`): a `Cluster` (operator-managed TLS certs, `hostssl` pg_hba enforcement, SCRAM-SHA-256, bootstrap db/owner `app`, checksummed data, plugin-based WAL archiving), a barman-cloud `ObjectStore` (`barmancloud.cnpg.io/v1`, gzip data and WAL, retention per environment), and a `ScheduledBackup` (`method: plugin`, `target: primary`, `{{ backup_schedule }}`).
- The CNPG operator (+ Barman Cloud plugin v0.11.0) installs cluster-wide via `deploy/flux/cnpg-operator-kustomization.yaml`; the per-environment app Kustomizations (`deploy/flux/kustomization-{dev,staging,prod}.yaml`) gain `dependsOn: cnpg-operator`, Cluster healthChecks, and SOPS decryption when the feature is enabled. The old dangling `deploy/flux/postgres-kustomization.yaml` was removed.
- Application runtime shipped with the same flag: sqlx 0.8.6 pool (lazy, small), embedded `sqlx::migrate!` migrations run at startup (`APP__POSTGRES__RUN_MIGRATIONS`, advisory locked), `PostgresConfig` in `src/config.rs`, demo `POST /api/v1/items` (upsert) and `GET /api/v1/items/{key}` handlers, `AppError::Database`, and DB readiness in `/health/ready` (never liveness).
- App wiring: `APP__POSTGRES__URL` injected from the auto-generated `<cluster>-app` secret, CNPG CA cert mounted at `/etc/secrets/pg-ca/ca.crt`.
- PgBouncer pooler (issue #142): `deploy/components/postgres-pooler/` Pooler CR (transaction mode, SCRAM, forced client TLS, per-env 1/2/4 instances) routed through `APP__POSTGRES__HOST`; the Cluster's `serverAltDNSNames` gains the pooler name so `verify-full` remains satisfied through the reused cluster server cert.

### Added
- Initial release from template
- Knative Serving support
- FluxCD GitOps integration
{% if feature_s3 %}
- S3/MinIO storage support via OpenDAL
- S3 CRUD operations API
{% endif %}
- OpenTelemetry observability stack
- Prometheus metrics
- Distributed tracing with Jaeger
- Structured JSON logging
- Health check endpoints
- Integration tests
- CI/CD pipeline
- **CloudNative PostgreSQL with Automated Backups** (Branch: `001-cloudnative-postgres-backups`)
  - High-availability PostgreSQL cluster (3-replica configuration for production)
  - Automatic failover within 6 seconds (vs. 2-minute requirement)
  - Automated daily backups with configurable retention (7-30 days)
  - Point-in-Time Recovery (PITR) via WAL streaming and backups
  - PgBouncer connection pooling for efficient client management
  - Prometheus metrics and PrometheusRule alerts for backup/replication monitoring
  - FluxCD GitOps integration for declarative cluster management
  - Environment-specific overlays (dev/staging/prod) with configurable resource limits
  - Comprehensive operational scripts for backup, restore, and status monitoring
  - E2E test suite with 100% pass rate (4/4 tests in ~10 minutes)
  - Complete documentation: deployment, backup/restore, monitoring, FluxCD integration

### Changed
- None

### Deprecated
- None

### Removed
- None

### Fixed
- Fixed CloudNativePG 1.28 compatibility issues in E2E test fixtures
- Fixed heredoc multi-line SQL in failover test script

### Security
- SOPS encryption configured for secret management
- Kubernetes RBAC with minimal required permissions
- Optional SSE-S3 encryption for production backups

---

## [Versioning](#versioning)

This project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

### Version Format

`MAJOR.MINOR.PATCH`

- **MAJOR**: Incompatible API changes
- **MINOR**: Backwards-compatible functionality additions
- **PATCH**: Backwards-compatible bug fixes

### Pre-release Identifiers

- `alpha`: Initial development
- `beta`: Feature complete, testing phase
- `rc`: Release candidate

Examples:
- `1.0.0-alpha.1`
- `1.0.0-beta.1`
- `1.0.0-rc.1`

---

## [Contribution Guidelines](#contribution-guidelines)

### When to Add an Entry

Add a changelog entry when:
- User-facing functionality changes
- API endpoint changes (add, remove, modify)
- Configuration options change
- Breaking changes
- Bug fixes affecting users
- Security vulnerabilities fixed

Do NOT add entries for:
- Internal refactoring
- Test updates
- Documentation improvements (unless user-facing)
- CI/CD changes

### Entry Format

```markdown
## [1.1.0] - 2024-01-15

### Added
- Add S3 upload endpoint `/api/upload`
- Add pagination to `/api/objects` endpoint

### Changed
- Update Knative Serving from v1.11 to v1.12
- Increase default Redis timeout from 3s to 5s

### Deprecated
- `/api/list` endpoint will be removed in v2.0.0
  Use `/api/objects` instead

### Removed
- Remove legacy `/api/v1/*` endpoints

### Fixed
- Fix S3 connection timeout issues
- Fix panic on invalid Redis URL

### Security
- Update `redis` crate from 0.23.0 to 0.23.1 (security fix)
```

### Commit Messages

Link commits to changelog entries:

```bash
git commit -m "feat(api): add S3 upload endpoint

Closes #123

See CHANGELOG.md"
```

---

## [Release Checklist](#release-checklist)

Before releasing a new version:

- [ ] Update `Cargo.toml` version
- [ ] Add entry to `CHANGELOG.md`
- [ ] Update `README.md` if needed
- [ ] Update `docs/API.md` if API changed
- [ ] Run full test suite
- [ ] Run `cargo clippy -- -D warnings`
- [ ] Run `cargo fmt --all --check`
- [ ] Run `cargo audit`
- [ ] Build and test Docker image
- [ ] Deploy to staging and verify
- [ ] Create Git tag: `git tag -a v1.0.0 -m "Release v1.0.0"`
- [ ] Push tags: `git push origin v1.0.0`
- [ ] Create GitHub release
- [ ] Update template version (if applicable)

---

## [Historical Versions](#historical-versions)

### [Template v1.0.0] - 2024-01-15

Initial template release.

#### Added
- Complete Rust + Knative + FluxCD template
- Docker-based local development
- Kubernetes deployment manifests
- Knative Serving configuration
- FluxCD GitOps setup
- OpenTelemetry integration
- Testing infrastructure
- Documentation suite
{% if feature_s3 %}
- S3/MinIO storage (optional)
{% endif %}

---

## [Categories Explained](#categories-explained)

### Added
New features or functionality.

Examples:
- New API endpoint
- New configuration option
- New dependency
- New feature flag

### Changed
Existing functionality modified.

Examples:
- Default value changed
- Behavior change (non-breaking)
- Library version update (non-security)
- Resource limit changed

### Deprecated
Features to be removed in future release.

Examples:
- API endpoint marked for removal
- Configuration option deprecated
- Command-line flag deprecated

### Removed
Features deleted from the codebase.

Examples:
- Deleted API endpoint
- Removed configuration option
- Removed feature

### Fixed
Bug fixes.

Examples:
- Memory leak fixed
- Race condition fixed
- Incorrect behavior corrected
- Error handling improved

### Security
Security-related changes.

Examples:
- Dependency update for security fix
- Security vulnerability mitigation
- Security feature added

---

## [Links](#links)

- [Current Version](../../tags)
- [Latest Release](https://github.com/your-org/{{ project_name }}/releases/latest)
- [GitHub Releases](https://github.com/your-org/{{ project_name }}/releases)
- [Contributing](CONTRIBUTING.md)
