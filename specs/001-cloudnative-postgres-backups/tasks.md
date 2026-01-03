---

description: "Task list for CloudNative PostgreSQL with Automated Backups"
---

# Tasks: CloudNative PostgreSQL with Automated Backups

**Input**: Design documents from `/specs/001-cloudnative-postgres-backups/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md (all complete)

**Tests**: E2E tests are REQUIRED per acceptance criteria in spec.md. Unit tests are NOT required (infrastructure-only feature).

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3, US4)
- Include exact file paths in descriptions

## Path Conventions

All paths are relative to repository root: `/Users/hcasten/Developer/rust-knative-flux-template.git/rust-knative-flux-template`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic structure for PostgreSQL manifests

- [x] T001 Create base directory structure: `deploy/base/`, `deploy/overlays/dev/`, `deploy/overlays/staging/`, `deploy/overlays/prod/`, `deploy/flux/`
- [x] T002 Create E2E test directory structure: `tests/e2e/fixtures/postgres/`, `tests/e2e/scripts/`
- [x] T003 [P] Create operational scripts directory: `scripts/dev/` (for postgres-specific scripts)
- [x] T004 [P] Create documentation directory: `docs/` (already exists, verify structure)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

### Infrastructure Setup

- [x] T005 Install CloudNativePG operator 1.28.0 in Kind cluster: Create `deploy/infrastructure/cloudnative-pg/operator/kustomization.yaml` referencing `https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.28/releases/cnpg-1.28.0.yaml`
- [x] T006 [P] Deploy MinIO for local object storage: Create `deploy/overlays/dev/infrastructure/minio.yaml` with credentials (access key: `minioadmin`, secret: `minioadmin`)
- [x] T007 Create object storage secret template: Create `deploy/base/object-storage-secret.yaml.example` with structure for `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`, `BUCKET_NAME`, `ENDPOINT_URL`
- [x] T008 Configure SOPS for secret encryption: Create `.sops.yaml` with Age encryption rules for `^(data|stringData)$` regex

### Base Manifests

- [x] T009 Create base PostgreSQL Cluster CRD manifest: Create `deploy/base/postgres-cluster.yaml` with 3 replicas, PostgreSQL 16, 1 CPU/2Gi memory, 200Gi storage, quorum replication, pg_stat_statements enabled
- [x] T010 Create base ScheduledBackup manifest: Create `deploy/base/postgres-backup.yaml` with daily schedule (cron: `0 2 * * *`), 30-day retention, zstd compression, streaming WAL archiving (5min interval)
- [x] T011 [P] Create base PgBouncer pooler manifest: Create `deploy/base/postgres-pooler.yaml` with 300 max_client_conn, transaction pooling mode
- [x] T012 Update base kustomization: Update `deploy/base/kustomization.yaml` to include postgres-cluster.yaml, postgres-backup.yaml, postgres-pooler.yaml, object-storage-secret.yaml

### FluxCD Integration

- [ ] T013 Create FluxCD GitRepository source: Create `deploy/flux/git-repository-postgres.yaml` referencing the repository with branch `001-cloudnative-postgres-backups`
- [ ] T014 Create FluxCD Kustomization for PostgreSQL: Create `deploy/flux/postgres-kustomization.yaml` targeting `deploy/overlays/dev/` with SOPS decryption enabled, 5-minute reconciliation interval
- [ ] T015 Add operator dependency: Update `deploy/flux/postgres-kustomization.yaml` to depend on `cnpg-system` namespace and CloudNativePG operator being ready

**Checkpoint**: Foundation ready - user story implementation can now begin in parallel

---

## Phase 3: User Story 1 - Deploy PostgreSQL Cluster with High Availability (Priority: P1) 🎯 MVP

**Goal**: Operators can deploy a highly-available PostgreSQL cluster that survives node failures and provides continuous database service

**Independent Test**: Deploy cluster → verify all replicas healthy → terminate one pod → verify automatic recovery within 2 minutes

### Environment Overlays for User Story 1

- [ ] T016 [P] [US1] Create dev overlay: Create `deploy/overlays/dev/postgres-cluster-patch.yaml` with 1 replica, async replication, 500m CPU/512Mi memory, 20Gi storage
- [ ] T017 [P] [US1] Create staging overlay: Create `deploy/overlays/staging/postgres-cluster-patch.yaml` with 2 replicas, async replication, 750m CPU/1Gi memory, 100Gi storage
- [ ] T018 [P] [US1] Create prod overlay: Create `deploy/overlays/prod/postgres-cluster-patch.yaml` with 3 replicas, quorum replication (`ANY 1 (*)`), 1 CPU/2Gi memory, 200Gi storage
- [ ] T019 [US1] Create dev kustomization: Create `deploy/overlays/dev/kustomization.yaml` referencing base and applying dev patches
- [ ] T020 [US1] Create staging kustomization: Create `deploy/overlays/staging/kustomization.yaml` referencing base and applying staging patches
- [ ] T021 [US1] Create prod kustomization: Create `deploy/overlays/prod/kustomization.yaml` referencing base and applying prod patches

### Operational Scripts for User Story 1

- [ ] T022 [P] [US1] Create PostgreSQL deployment script: Create `scripts/dev/deploy-postgres.sh` to apply operator, create MinIO, apply cluster manifest, wait for ready state
- [ ] T023 [P] [US1] Create port-forward script: Create `scripts/dev/port-forward-postgres.sh` to expose PostgreSQL on localhost:5432
- [ ] T024 [P] [US1] Create cluster status script: Create `scripts/dev/check-postgres-status.sh` to query cluster health, replica count, replication lag

### E2E Tests for User Story 1

- [ ] T025 [US1] Create test cluster fixture: Create `tests/e2e/fixtures/postgres/test-cluster.yaml` with 2 replicas, 500m CPU/512Mi memory, 2Gi storage
- [ ] T026 [US1] Create E2E script for operator installation: Create `tests/e2e/scripts/07-deploy-postgres.sh` to install CloudNativePG operator, wait for operator pod ready
- [ ] T027 [US1] Create E2E script for cluster deployment: Create `tests/e2e/scripts/08-test-postgres-deployment.sh` to apply test cluster, wait for ready state (<5 min), verify primary elected, verify replicas syncing
- [ ] T028 [US1] Create E2E script for failover test: Create `tests/e2e/scripts/10-test-failover.sh` to delete primary pod, verify new primary elected (<2 min), verify zero data loss (query test data)
- [ ] T029 [US1] Update E2E cleanup script: Update `tests/e2e/scripts/99-cleanup.sh` to delete PostgreSQL cluster, operator, MinIO

### Validation for User Story 1

- [ ] T030 [US1] Validate AC1: Cluster reaches healthy state within 5 minutes (test in script 08)
- [ ] T031 [US1] Validate AC2: Applications can connect and execute queries (test in script 08 with psql command)
- [ ] T032 [US1] Validate AC3: Cluster recovers from pod deletion within 2 minutes (test in script 10)

**Checkpoint**: User Story 1 (MVP) is complete - PostgreSQL cluster can be deployed and survives failures

---

## Phase 4: User Story 2 - Automated Daily Backups to Object Storage (Priority: P2)

**Goal**: Automated backups are created on schedule, stored in object storage, and retention policies are enforced

**Independent Test**: Configure backup schedule → wait for scheduled time → verify backup appears in object storage → verify backup metadata

### Backup Configuration for User Story 2

- [ ] T033 [P] [US2] Create dev backup schedule patch: Create `deploy/overlays/dev/postgres-backup-patch.yaml` with cron `0 3 * * *`, 7-day retention, gzip compression, MinIO endpoint
- [ ] T034 [P] [US2] Create staging backup schedule patch: Create `deploy/overlays/staging/postgres-backup-patch.yaml` with cron `0 2 * * *`, 14-day retention, zstd compression (level 3), S3 endpoint
- [ ] T035 [P] [US2] Create prod backup schedule patch: Create `deploy/overlays/prod/postgres-backup-patch.yaml` with cron `0 2 * * *`, 30-day retention, zstd compression (level 3), S3 endpoint, SSE-S3 encryption
- [ ] T036 [US2] Update dev kustomization: Update `deploy/overlays/dev/kustomization.yaml` to include backup patches
- [ ] T037 [US2] Update staging kustomization: Update `deploy/overlays/staging/kustomization.yaml` to include backup patches
- [ ] T038 [US2] Update prod kustomization: Update `deploy/overlays/prod/kustomization.yaml` to include backup patches

### Operational Scripts for User Story 2

- [ ] T039 [P] [US2] Create manual backup trigger script: Create `scripts/dev/create-backup.sh` to create ad-hoc Backup CRD, wait for completion, verify checksum
- [ ] T040 [P] [US2] Create backup status script: Create `scripts/dev/check-backup-status.sh` to list backups, show status, size, timestamps, object storage location
- [ ] T041 [P] [US2] Create backup list script: Create `scripts/dev/list-backups.sh` to query object storage (MinIO/S3) and list available backups with sizes

### E2E Tests for User Story 2

- [ ] T042 [US2] Create test data SQL fixture: Create `tests/e2e/fixtures/postgres/test-data.sql` with 1GB data generation (1M rows with ~800 bytes each)
- [ ] T043 [US2] Create test backup config fixture: Create `tests/e2e/fixtures/postgres/test-backup-config.yaml` with immediate schedule, 7-day retention, gzip compression
- [ ] T044 [US2] Create E2E script for backup creation: Create `tests/e2e/scripts/09-test-backup-restore.sh` (part 1) to insert test data, trigger backup, wait for completion (<5 min for 1GB), verify backup in MinIO
- [ ] T045 [US2] Extend E2E script for backup validation: Extend `tests/e2e/scripts/09-test-backup-restore.sh` to verify checksum present, verify size >0, verify object storage location correct

### Validation for User Story 2

- [ ] T046 [US2] Validate AC1: Backup completes within 30 minutes for 10GB database (test with 1GB in ~3-5 min)
- [ ] T047 [US2] Validate AC2: Retention policy removes expired backups (test by setting 1-day retention, creating backup, advancing time)
- [ ] T048 [US2] Validate AC3: Backup runs without disrupting connections (test with concurrent psql queries during backup)
- [ ] T049 [US2] Validate AC4: Failed backup logs error with details (test by removing object storage credentials)

**Checkpoint**: User Story 2 is complete - Automated backups work and are stored in object storage

---

## Phase 5: User Story 3 - Point-in-Time Database Restore (Priority: P3)

**Goal**: Operators can restore a PostgreSQL database from a backup or to a specific point in time

**Independent Test**: Use existing backup → create restore cluster manifest → verify new cluster with restored data → verify data matches expected state

### Operational Scripts for User Story 3

- [ ] T050 [US3] Create restore script: Create `scripts/dev/restore-from-backup.sh` to generate restore Cluster CRD with `bootstrap.recovery`, apply manifest, wait for new cluster ready, verify data integrity

### E2E Tests for User Story 3

- [ ] T051 [US3] Extend E2E script for restore testing: Extend `tests/e2e/scripts/09-test-backup-restore.sh` (part 2) to create restore cluster from backup, wait for restore completion (<10 min for 1GB), verify restored data matches original
- [ ] T052 [US3] Create E2E script for PITR testing: Extend `tests/e2e/scripts/09-test-backup-restore.sh` (part 3) to insert data, record timestamp, insert more data, restore to timestamp, verify only first data present
- [ ] T053 [US3] Create E2E script for restore failure handling: Create test case to corrupt backup file, attempt restore, verify failure message is clear and actionable

### Validation for User Story 3

- [ ] T054 [US3] Validate AC1: Restore from backup completes within 15 minutes for 10GB database (test with 1GB in ~8-10 min)
- [ ] T055 [US3] Validate AC2: PITR restores to exact timestamp by replaying WAL files (test with timestamp between backups)
- [ ] T056 [US3] Validate AC3: Restore failure reports specific error details (test with corrupted backup)
- [ ] T057 [US3] Validate AC4: Restored data maintains integrity (test constraints, indexes, relationships)

**Checkpoint**: User Story 3 is complete - Database restore and PITR work correctly

---

## Phase 6: User Story 4 - Monitor Backup Health and Storage Usage (Priority: P3)

**Goal**: Operators have visibility into backup status, success rates, storage consumption, and can proactively identify issues

**Independent Test**: Query backup metrics → verify success/failure counts accurate → verify storage usage reflects actual consumption → validate alerts fire on failures

### Monitoring Configuration for User Story 4

- [ ] T058 [P] [US4] Create PodMonitor for PostgreSQL metrics: Create `deploy/base/postgres-podmonitor.yaml` targeting CloudNativePG pods on port 9187, 30-second interval
- [ ] T059 [P] [US4] Create PrometheusRule for backup alerts: Create `deploy/base/postgres-alerts.yaml` with alerts for backup failure (>5 min), replication lag (>10s), instance down (>1 min)
- [ ] T060 [US4] Update base kustomization: Update `deploy/base/kustomization.yaml` to include postgres-podmonitor.yaml and postgres-alerts.yaml

### Dashboards and Documentation for User Story 4

- [ ] T061 [P] [US4] Document Grafana dashboard setup: Create `docs/POSTGRES_MONITORING.md` with instructions to import CloudNativePG dashboard from `https://github.com/cloudnative-pg/grafana-dashboards`
- [ ] T062 [P] [US4] Document key metrics: Update `docs/POSTGRES_MONITORING.md` with descriptions of `cnpg_collector_last_failed_backup_timestamp`, `cnpg_pg_replication_lag`, `cnpg_collector_up`, `cnpg_pg_stat_archiver_failed_count`

### E2E Tests for User Story 4

- [ ] T063 [US4] Create E2E script for metrics validation: Create `tests/e2e/scripts/11-test-monitoring.sh` to query Prometheus for backup metrics, verify values match expected state, trigger backup failure, verify alert fires within 5 minutes

### Validation for User Story 4

- [ ] T064 [US4] Validate AC1: Backup metrics are accurate (success rate, duration, size)
- [ ] T065 [US4] Validate AC2: Alerts fire within 5 minutes of failure
- [ ] T066 [US4] Validate AC3: Storage metrics identify highest consumers

**Checkpoint**: User Story 4 is complete - Monitoring and alerting are functional

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Documentation, validation, and final improvements

### Documentation

- [ ] T067 [P] Create main PostgreSQL operations guide: Create `docs/POSTGRES.md` with deployment instructions, connection examples, configuration reference, troubleshooting section
- [ ] T068 [P] Create backup and restore procedures guide: Create `docs/POSTGRES_BACKUP_RESTORE.md` with backup configuration, manual backup triggers, restore procedures, PITR examples, disaster recovery workflows
- [ ] T069 [P] Update main README: Update `README.md` to mention PostgreSQL support, link to `docs/POSTGRES.md`, add quickstart example
- [ ] T070 [P] Create quickstart guide: Create `specs/001-cloudnative-postgres-backups/quickstart.md` with 5-minute deployment walkthrough, connection test, backup verification

### Validation and Compliance

- [ ] T071 Validate manifest syntax: Create `scripts/validate-postgres-manifests.sh` to run `kubectl apply --dry-run=client` on all manifests, verify no errors
- [ ] T072 Run E2E test suite: Execute all E2E tests (`07-deploy-postgres.sh` through `11-test-monitoring.sh`), verify all pass, verify total time <30 minutes
- [ ] T073 Validate success criteria: Review all 10 success criteria from spec.md, verify each is met with evidence from E2E tests or monitoring data
- [ ] T074 Update CHANGELOG: Update `docs/CHANGELOG.md` with feature summary, user story highlights, breaking changes (if any), migration guide (if applicable)

### Optional: Rust Integration Test (if needed)

- [ ] T075 [OPTIONAL] Create Rust PostgreSQL connection test: Create `tests/integration/postgres_connection_test.rs` with `tokio_postgres` client, test connection, basic query, parameterized query, error handling
- [ ] T076 [OPTIONAL] Add PostgreSQL connection pool to app state: Update `src/state.rs` to include `deadpool_postgres` connection pool, configure from `config.toml`
- [ ] T077 [OPTIONAL] Add PostgreSQL health check endpoint: Update `src/handlers/health.rs` to add `/health/postgres` endpoint that tests database connectivity

### Security and Best Practices

- [ ] T078 Review secret management: Verify no secrets in plaintext, verify SOPS encryption works, test secret rotation procedure
- [ ] T079 Review RBAC permissions: Verify CloudNativePG operator has minimal required permissions, verify application service accounts don't have cluster-admin
- [ ] T080 Validate encryption: Verify SSE-S3 enabled in production backup config, verify TLS for PostgreSQL connections (sslmode=require)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Stories (Phase 3-6)**: All depend on Foundational phase completion
  - User stories can proceed in parallel (if staffed)
  - Or sequentially in priority order (US1 → US2 → US3 → US4)
- **Polish (Phase 7)**: Depends on all user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Foundational (Phase 2) - No dependencies on other stories
- **User Story 2 (P2)**: Depends on User Story 1 (needs cluster to back up) - Independently testable with own cluster
- **User Story 3 (P3)**: Depends on User Story 2 (needs backups to restore) - Independently testable with existing backup
- **User Story 4 (P3)**: Can start after Foundational (Phase 2) - No dependencies on other stories (metrics exist from cluster creation)

### Within Each User Story

- Environment overlays can be created in parallel ([P] tasks)
- Operational scripts can be created in parallel ([P] tasks)
- E2E tests depend on fixtures being created first
- Validation tasks run after E2E tests complete

### Parallel Opportunities

- Phase 1: All setup tasks can run in parallel
- Phase 2: Tasks T006 (MinIO), T007 (secret template), T011 (pooler) can run in parallel
- Phase 3 (US1): T016-T018 (overlays), T022-T024 (scripts) can run in parallel
- Phase 4 (US2): T033-T035 (backup patches), T039-T041 (scripts) can run in parallel
- Phase 6 (US4): T058-T059 (monitoring), T061-T062 (docs) can run in parallel
- Phase 7: T067-T070 (documentation) can run in parallel

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL - blocks all stories)
3. Complete Phase 3: User Story 1 (PostgreSQL cluster deployment)
4. **STOP and VALIDATE**: Run E2E tests for US1 (scripts 07, 08, 10)
5. Demo PostgreSQL cluster with failover capability
6. **Decision point**: Continue to backups (US2) or deploy MVP

### Incremental Delivery

1. Setup + Foundational → Foundation ready
2. Add User Story 1 → Test independently → Deploy/Demo (MVP: HA PostgreSQL cluster)
3. Add User Story 2 → Test independently → Deploy/Demo (Backups)
4. Add User Story 3 → Test independently → Deploy/Demo (Restore)
5. Add User Story 4 → Test independently → Deploy/Demo (Monitoring)
6. Polish → Final validation → Production-ready

### Parallel Team Strategy

With multiple developers (after Foundational phase complete):

1. **Developer A**: User Story 1 (cluster deployment) - Priority 1
2. **Developer B**: User Story 4 (monitoring) - Can start in parallel, no dependencies
3. After US1 complete:
   - **Developer A**: User Story 2 (backups) - Depends on US1
4. After US2 complete:
   - **Developer A**: User Story 3 (restore) - Depends on US2
5. After all stories complete:
   - **All developers**: Polish (Phase 7)

---

## Notes

- [P] tasks = different files, no dependencies, can run in parallel
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- This is an **infrastructure-only** feature - no Rust application code changes required
- All configurations follow **GitOps** pattern via FluxCD
- E2E tests use **Kind cluster** with resource constraints (8Gi memory, 4 CPU)
- Test database size is **<1GB** to meet <30 minute E2E test target
- **SOPS + Age** encryption for secrets management
- **CloudNativePG operator 1.28.0** with PostgreSQL 16
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
