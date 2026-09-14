# Production Deploy Capability: `prod-deploy` Target, GitHub Environment, and GHA Workflow

## TL;DR

> **Quick Summary**: Add a standalone `make prod-deploy` target that deploys this service to the production Kubernetes cluster via FluxCD (ensure GitRepository source + auto-create SSH deploy key if needed → apply prod Flux config → wait for reconciliation → verify Knative service → run an in-cluster health smoke suite), plus a `make prod-github-env` setup target that creates the GitHub `production` environment via `gh api`, plus a templated GitHub Actions deploy workflow with in-cluster ARC runner RBAC.
>
> **Deliverables**:
> - `make prod-deploy` + `make prod-kubeconfig` + `scripts/prod/deploy.sh` (full deploy orchestration with deploy-key auto-detection)
> - `make prod-github-env` + `scripts/prod/create-github-env.sh` (GitHub environment setup via `gh api`)
> - `deploy/flux/git-repository.yaml` switched to SSH URL + uncommented `secretRef: github-deploy-key`
> - `deploy/overlays/prod/namespace.yaml` (creates the missing `production` Namespace)
> - `deploy/infrastructure/gha-runner/rbac.yaml.liquid` + `serviceAccountName` wiring (in-cluster kubectl for runner jobs)
> - `.github/workflows/deploy.yaml.liquid` (tag push v* + workflow_dispatch → `environment: production`)
> - `scripts/test-prod-deploy-static.sh` (TDD static validation harness across the feature-flag matrix)
> - Focused docs section in `docs/DEPLOYMENT.md` + README pointer
>
> **Estimated Effort**: Medium
> **Parallel Execution**: YES - 4 waves
> **Critical Path**: Task 1 (harness) → Task 2 (SSH switch) → Task 3 (prod-deploy) → Task 6 (workflow) → Task 8 (sweep) → F1-F4

---

## Context

### Original Request
User request 1: "we need a make target which deploys this service to the production kubernetes cluster and tests it, this should start the gitrepo, make sure the helm chart exists in flux and optionally adds a deploy key if one is needed"

User request 2: "actually, lets set up github environments too so that this can be deployed from gha"

### Interview Summary
**Key Discussions** (all confirmed via Question tool):
- **Target design**: Standalone `make prod-deploy` — independent of existing `make bootstrap [env]` (Makefile:252-290)
- **Deploy key**: Auto-detect via GitRepository auth failure → create secret → print public key → POLL non-interactively (~5m timeout) so it works in CI too
- **Template change**: `git-repository.yaml` always references the `github-deploy-key` secretRef (uncommented) → hence SSH URL
- **Test method**: In-cluster detached-pod curl (robust regardless of ingress reachability)
- **Test scope**: Health smoke suite — `/health/live`, `/health/ready`, `/metrics`, `/api/v1/hello`
- **Kubeconfig**: `KUBECONFIG` env override → `.kubeconfig-prod` file fallback + `prod-kubeconfig` helper target
- **Image**: No build — deploy existing image; Flux image automation owns tags
- **GHA auth**: In-cluster ARC runner + ServiceAccount/RBAC (not kubeconfig secret)
- **GHA trigger**: Tag push (`v*`) + `workflow_dispatch`
- **Env protection**: Deployment branch policy only (`main` + `v*` tags), no required reviewers
- **Env setup**: Dedicated `make prod-github-env` target (local-only, `gh` CLI)

**Research Findings**:
- `make bootstrap` (Makefile:252-290) already applies `deploy/flux/git-repository.yaml` + `deploy/flux/config/$ENV` via `kubectl apply --server-side` — the new target reuses these commands standalone
- Makefile is liquid-templated: `PROJECT_NAME := {{ project_name | replace: "_", "-" }}` (L8), `CRATE_NAME` (L10) — but has NO `github_org`/`github_repo` vars (gap)
- GitRepository (deploy/flux/git-repository.yaml): HTTPS URL, `secretRef: github-deploy-key` COMMENTED OUT; Flux Kustomization `<project>-prod` → `./deploy/overlays/prod`, wait:true, timeout 5m
- HelmRelease renders chart `./deploy/chart` from the SAME GitRepository (inline chart spec); prod overlay namespace = `production`
- Canonical patterns: `kubectl wait --for=condition=Ready ksvc/<name> -n <ns> --timeout=5m` (scripts/dev/build-and-deploy.sh:135); URL via `-o jsonpath='{.status.url}'`; failure = diagnostic dump (ksvc yaml, pods, logs, events)
- The repo's existing `kubectl_curl` (scripts/test-template-e2e-local.sh:444-445) is ATTACH-mode (`--rm -i`) — the detached-pod pattern is NEW code
- ARC runner helmrelease (deploy/infrastructure/gha-runner/helmrelease.yaml) has NO `serviceAccountName`; runner image is bare (no kubectl/flux preinstalled); `containerMode: kubernetes`
- ci.yaml.liquid:20 convention: `runs-on: {% if feature_gha_runner %}<name>-runner{% else %}ubuntu-latest{% endif %}`
- KNOWN BUG (out of scope): scripts/dev/{deploy-postgres,check-postgres-status,port-forward-postgres}.sh source non-existent `common.sh` — new scripts must NOT source it

### Metis Review
**Identified Gaps** (all addressed in this plan):
- **Gap 1 (critical)**: No `production` Namespace resource exists anywhere in `deploy/` — prod-deploy would hang → FIXED by Task 2 (namespace.yaml in prod overlay)
- **Gap 2**: Flagger `dependsOn` unsatisfied in prod (`config/prod` never applies the flagger operator) → FIXED by Task 3 pre-flight check (fail-fast; NEVER auto-install — cluster-wide ownership rule per AGENTS.md)
- **Gap 3**: Makefile lacks `GITHUB_ORG`/`GITHUB_REPO` → FIXED by Task 3 (liquid vars, baked at generation time)
- **Gap 4**: RBAC missing HelmChart read + conditional image-automation CRs (`enable_image_updates`) → FIXED by Task 4 (conditional `{% if enable_image_updates %}` rules)
- **Gap 5**: e2e harness generates with `github_org = "test-org"` — SSH switch breaks template CI → FIXED by Task 2 (post-generation override in test-template-e2e-local.sh)
- **Gap 6**: detached-pod curl does not exist in repo → Task 3 writes it as NEW code
- **Edge cases folded in**: .gitignore missing `.kubeconfig-prod`; ksvc URL unresolvable in-cluster → `.svc.cluster.local` fallback; first-CI-run deploy-key timeout is by-design (exit 1 + instructions, never rotate secret); concurrency/permissions/timeout in workflow; secret-exists guard (print existing pubkey, don't recreate)

---

## Work Objectives

### Core Objective
Enable a one-command, GitOps-native production deployment (`make prod-deploy`) that is also executable from GitHub Actions using a properly protected GitHub environment, with automated post-deploy verification.

### Concrete Deliverables
1. `scripts/prod/deploy.sh` — prod deploy orchestration (Gen-1 script style)
2. `scripts/prod/create-github-env.sh` — GitHub environment creation
3. `scripts/test-prod-deploy-static.sh` — static validation harness (TDD, written first)
4. Makefile additions: `prod-deploy`, `prod-github-env`, `prod-kubeconfig` targets + `PROD_KUBECONFIG_PATH`, `GITHUB_ORG`, `GITHUB_REPO`, `GITHUB_REPO_SSH` vars
5. `deploy/flux/git-repository.yaml` — SSH URL + uncommented secretRef
6. `deploy/overlays/prod/namespace.yaml` — `production` Namespace
7. `deploy/infrastructure/gha-runner/rbac.yaml.liquid` + helmrelease `serviceAccountName`
8. `.github/workflows/deploy.yaml.liquid`
9. `.gitignore` entry for `.kubeconfig-prod`
10. `docs/DEPLOYMENT.md` section + README pointer

### Definition of Done
- [ ] `scripts/test-prod-deploy-static.sh` exits 0 across the full feature-flag matrix (gha_runner × image_updates × flagger)
- [ ] `bash -n` clean on all new scripts; `make -n prod-deploy` and `make -n prod-github-env` dry-run cleanly
- [ ] `kustomize build deploy/overlays/prod` (rendered) contains `namespace: production`; `kustomize build deploy/infrastructure/gha-runner` contains the SA + RoleBindings
- [ ] Zero `{%` liquid residue in any rendered output
- [ ] Existing dev flow (`make bootstrap`, dev e2e) unaffected
- [ ] Idempotency: secret-existence guard + server-side applies + re-entrant waits (second run succeeds without recreating the deploy key)

### Must Have
- Non-interactive everywhere: every wait is a poll with timeout, every failure exits non-zero with diagnostics
- Pre-flight checks: cluster reachable, Flux installed, Knative installed, Flagger dependency satisfied (if `dependsOn: flagger`)
- Deploy key handling: check secret existence FIRST; create + print pubkey + poll if missing; never rotate an existing secret
- Smoke suite: 4 exact checks (`{"status":"alive"}`, `{"status":"ready"}`, `# HELP`, `message`) with `--max-time 60` (scale-to-zero cold start) via detached pod
- All name-bearing files liquid-templated
- Workflow: `permissions: contents: read`, per-ref `concurrency` (queue, don't cancel), `timeout-minutes: 45`, pinned kubectl + flux CLI versions

### Must NOT Have (Guardrails)
- MUST NOT modify any existing `dev-*` target or `KUBECONFIG_PATH := .kubeconfig-dev` semantics
- MUST NOT make `prod-deploy` interactive (no `read -p`)
- MUST NOT rotate/overwrite an existing `github-deploy-key` secret
- MUST NOT build/push images or touch HelmRelease image tags (Flux image automation owns that)
- MUST NOT apply workloads directly (no kubectl apply of ksvc/HelmRelease content — only Flux config objects)
- MUST NOT auto-install the Flagger operator (fail-fast pre-flight only)
- MUST NOT fix the `common.sh` bug or source `common.sh` in new scripts (it doesn't exist)
- MUST NOT add `make staging-deploy` / `prod-destroy` / rollback targets (rollback = git revert + Flux; document only)
- MUST NOT call `prod-github-env` from CI (CI's GITHUB_TOKEN cannot create environments)
- MUST NOT use `@latest` tool versions in the workflow

---

## Verification Strategy (MANDATORY)

> **ZERO HUMAN INTERVENTION** - ALL verification is agent-executed. No exceptions.
> Runtime verification against a real production cluster is a one-time OPERATOR step, clearly
> separated from automated gates (no prod cluster exists in CI). Everything else is
> agent-executable below.

### Test Decision
- **Infrastructure exists**: YES (cargo test; shell validation scripts)
- **Automated tests**: YES (Tests-after / TDD hybrid — the static harness is written FIRST as the red gate)
- **Framework**: bash harness (`scripts/test-prod-deploy-static.sh`) + existing validation script conventions; Rust code untouched

### QA Policy
Every task MUST include agent-executed QA scenarios (see TODO template below).
Evidence saved to `.sisyphus/evidence/task-{N}-{scenario-slug}.{ext}`.

- **Shell scripts**: `bash -n` + `shellcheck` (if available) + grep structural assertions + `--dry-run` mode execution
- **YAML/Manifests**: `kustomize build` on rendered (generated) project + `python3 -c "import yaml; yaml.safe_load(...)"` parse + grep assertions; liquid residue check (`grep -r '{%'` on rendered output must be empty)
- **Harness**: `cargo generate` into temp dirs across the feature-flag matrix; assertions per Metis §5
- **Runtime smoke suite**: specified with exact endpoints/strings; executable only against a real cluster (documented operator step) — QA scenarios for Task 3 use `--dry-run` + static assertions as the automated gate

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Start Immediately - TDD foundation):
└── Task 1: Static validation harness (TDD red) [quick]

Wave 2 (After Task 1 - independent feature work, MAX PARALLEL):
├── Task 2: GitRepository SSH switch + prod namespace + e2e mitigation [quick]
├── Task 4: gha-runner RBAC + serviceAccountName [quick]
└── Task 5: prod-github-env script + target [quick]

Wave 3 (After Wave 2 - core orchestration):
├── Task 3: prod-deploy target + deploy.sh [deep]
└── Task 6: deploy.yaml.liquid workflow [quick]

Wave 4 (After Wave 3):
└── Task 7: Docs + README pointer [writing]

Wave 5 (After Task 7):
└── Task 8: Final validation sweep [unspecified-high]

Wave FINAL (After ALL tasks - 4 parallel reviews, then user okay):
├── Task F1: Plan compliance audit (oracle)
├── Task F2: Code quality review (unspecified-high)
├── Task F3: Real QA execution (unspecified-high)
└── Task F4: Scope fidelity check (deep)
-> Present results -> Get explicit user okay

Critical Path: Task 1 → Task 2 → Task 3 → Task 6 → Task 8 → F1-F4 → user okay
Parallel Speedup: ~40% faster than sequential
Max Concurrent: 3 (Wave 2)
```

### Dependency Matrix

| Task | Depends On | Blocks |
|------|-----------|--------|
| 1 (harness) | — | 2, 3, 4, 5, 6 |
| 2 (SSH + ns + e2e) | 1 | 3 |
| 3 (prod-deploy) | 1, 2 | 6, 7 |
| 4 (RBAC) | 1 | 7 |
| 5 (github-env) | 1 | 7 |
| 6 (workflow) | 1, 3 | 7 |
| 7 (docs) | 2, 3, 4, 5, 6 | 8 |
| 8 (sweep) | 7 | F1-F4 |
| F1-F4 | 8 | user okay |

### Agent Dispatch Summary

- **Wave 1**: Task 1 → `quick` + skills `[test-gen]`
- **Wave 2**: Task 2 → `quick` + `[git-master]`; Task 4 → `quick` + `[k8s-microservices-debug]`; Task 5 → `quick` + `[]`
- **Wave 3**: Task 3 → `deep` + `[fluxcd-setup, deployment-planning]`; Task 6 → `quick` + `[ci-cd]`
- **Wave 4**: Task 7 → `writing` + `[document]`
- **Wave 5**: Task 8 → `unspecified-high` + `[review]`
- **FINAL**: F1 → `oracle`; F2 → `unspecified-high`; F3 → `unspecified-high`; F4 → `deep`

---

## TODOs

- [x] 1. Static Validation Harness (TDD — write FIRST, watch it fail)

  **What to do**:
  - Create `scripts/test-prod-deploy-static.sh` following Gen-1 script conventions (`#!/bin/bash`, `set -euo pipefail`, SCRIPT_DIR/PROJECT_ROOT derivation, ANSI colors, `→/✓/✗` echoes)
  - The harness must `cargo generate` the template into temp dirs (use `mktemp -d`, clean up with trap) once per feature-flag combination in the matrix: `feature_gha_runner` on/off × `enable_image_updates` on/off × `feature_flagger` on/off (8 combos)
  - For each generated project, assert (each failure names the missing artifact and the combo that failed):
    - `bash -n` passes on `scripts/prod/deploy.sh`, `scripts/prod/create-github-env.sh`
    - `kustomize build deploy/flux/config/prod` exits 0 AND output contains no `{%` residue
    - `kustomize build deploy/overlays/prod` exits 0 AND output contains `namespace: production` AND contains a `kind: Namespace` resource
    - `kustomize build deploy/infrastructure/gha-runner` exits 0 AND contains one `kind: ServiceAccount`, two `kind: RoleBinding`, and (when image_updates on) image-automation CR rules; no `{%` residue
    - Rendered `.github/workflows/deploy.yaml` parses via `python3 -c "import yaml; yaml.safe_load(...)"`
    - grep assertions: Makefile contains `prod-deploy:`, `prod-github-env:`, `prod-kubeconfig:`, `PROD_KUBECONFIG_PATH`, `GITHUB_ORG`; `deploy/flux/git-repository.yaml` contains uncommented `secretRef:` with `name: github-deploy-key` and URL `ssh://git@github.com`; workflow contains `environment: production`, the runs-on conditional, `concurrency:`, pinned tool versions
    - RBAC consistency: RoleBinding `subjects[].namespace` equals `actions-runner-system`
  - Support `PROD_DEPLOY_MATRIX="1,1,1"` style env override to run a single combo (comma-separated 0/1 flags) for fast iteration
  - Write the harness BEFORE any feature tasks; run it and confirm it fails naming the missing artifacts (red state)

  **Must NOT do**:
  - Do NOT create any of the feature artifacts this harness asserts on (Tasks 2-6 own those)
  - Do NOT require a Kubernetes cluster (pure static validation)
  - Do NOT source `common.sh` (does not exist)

  **Recommended Agent Profile**:
  - **Category**: `quick` — single mechanical script, assertions fully specified, no design decisions
  - **Skills**: [`test-gen`]
    - `test-gen`: test-harness structure and assertion design overlap directly
  - **Skills Evaluated but Omitted**:
    - `fluxcd-setup`: no cluster/Flux operations in this task
    - `git-master`: no git operations

  **Parallelization**:
  - **Can Run In Parallel**: NO (must complete first — everything depends on it)
  - **Parallel Group**: Wave 1 (alone)
  - **Blocks**: Tasks 2, 3, 4, 5, 6
  - **Blocked By**: None (can start immediately)

  **References** (CRITICAL - Be Exhaustive):

  **Pattern References** (existing code to follow):
  - `scripts/dev/setup-kind.sh` — canonical Gen-1 script skeleton: shebang, set -euo pipefail, SCRIPT_DIR/PROJECT_ROOT derivation, color block, `→/✓/✗` echo style
  - `scripts/test-template-e2e-local.sh` — how this repo invokes `cargo generate` programmatically (template vars, output dir handling); also line ~169 shows `github_org = "test-org"` generation vars
  - `Makefile:19-26` (help target) and `Makefile:252-290` (bootstrap) — what the grep assertions must find in the final Makefile

  **API/Type References** (contracts to implement against):
  - `deploy/overlays/prod/kustomization.yaml` — prod overlay structure the harness must kustomize-build
  - `deploy/infrastructure/gha-runner/kustomization.yaml` — file list the RBAC file must join
  - `.github/workflows/ci.yaml.liquid:20` — the runs-on conditional idiom the workflow assertion matches

  **Test References** (testing patterns to follow):
  - `scripts/validate-knative-service.sh` — existing repo validation script style (assert + fail with message)
  - `scripts/test-template-matrix.sh` — existing flag-matrix test runner (how the repo iterates template feature flags)

  **External References** (libraries and frameworks):
  - cargo-generate CLI: `https://cargo-generate.github.io/cargo-generate/` — `cargo generate --git <path> --name <n>` usage with template_vars/defaults files

  **WHY Each Reference Matters**:
  - setup-kind.sh gives the exact house script skeleton so the harness looks native
  - test-template-e2e-local.sh shows how to generate projects programmatically — copy its cargo-generate invocation pattern
  - test-template-matrix.sh shows the established flag-matrix iteration pattern to mirror

  **Acceptance Criteria**:

  > **AGENT-EXECUTABLE VERIFICATION ONLY** - No human action permitted.

  - [ ] `bash -n scripts/test-prod-deploy-static.sh` → exit 0
  - [ ] `./scripts/test-prod-deploy-static.sh` → exits NON-ZERO (red state) with output naming each missing artifact
  - [ ] Running with `PROD_DEPLOY_MATRIX="0,0,0"` completes the single-combo path without hanging

  **QA Scenarios (MANDATORY - task is INCOMPLETE without these):**

  ```
  Scenario: Harness syntax validity
    Tool: Bash
    Preconditions: repo checked out, no cluster needed
    Steps:
      1. Run `bash -n scripts/test-prod-deploy-static.sh`
      2. Assert exit code 0
    Expected Result: exit 0, empty stderr
    Failure Indicators: syntax error message, non-zero exit
    Evidence: .sisyphus/evidence/task-1-bashn.txt

  Scenario: TDD red state (harness fails naming missing artifacts)
    Tool: Bash
    Preconditions: feature tasks not yet implemented
    Steps:
      1. Run `./scripts/test-prod-deploy-static.sh 2>&1 | tee .sisyphus/evidence/task-1-red.txt`
      2. Assert exit code != 0
      3. Assert output contains at least: "prod-deploy", "git-repository", "production"
    Expected Result: non-zero exit; every assertion failure names the missing artifact and flag combo
    Failure Indicators: exit 0 (harness passes when it should fail), missing artifact names in output
    Evidence: .sisyphus/evidence/task-1-red.txt

  Scenario: Single-combo fast mode
    Tool: Bash
    Steps:
      1. Run `PROD_DEPLOY_MATRIX="0,0,0" ./scripts/test-prod-deploy-static.sh 2>&1 | tee .sisyphus/evidence/task-1-single.txt`
      2. Assert the harness ran exactly one cargo generate (count generation banners)
    Expected Result: exactly 1 combo executed, completes without hang
    Failure Indicators: 8 combos ran, or process hangs on cargo generate prompt
    Evidence: .sisyphus/evidence/task-1-single.txt
  ```

  > **Specificity requirements met**: exact commands, exact exit codes, exact artifact names.

  **Evidence to Capture:**
  - [ ] task-1-bashn.txt, task-1-red.txt, task-1-single.txt

  **Commit**: YES
  - Message: `test(prod): add static validation harness for prod deployment tooling`
  - Files: `scripts/test-prod-deploy-static.sh`
  - Pre-commit: `bash -n scripts/test-prod-deploy-static.sh`

- [x] 2. GitRepository SSH Switch + Production Namespace + Overlay Patch Fix

  **What to do**:
  - Edit `deploy/flux/git-repository.yaml`:
    - Change `spec.url` from `https://github.com/{{ github_org }}/{{ github_repo }}` to `ssh://git@github.com/{{ github_org }}/{{ github_repo }}.git`
    - Uncomment the `secretRef: {name: github-deploy-key}` block (currently lines 11-13) so it is active YAML
    - Keep `interval: 1m`, `ref.branch: {{ default_branch }}` unchanged
  - Create `deploy/overlays/prod/namespace.yaml`: `apiVersion: v1`, `kind: Namespace`, `metadata.name: production` with a standard template label; add it to `deploy/overlays/prod/kustomization.yaml` `resources` list (FIRST entry)
  - **BLOCKER FIX (discovered during Task 1, empirically validated)**: the SMP patches in `deploy/overlays/{prod,staging,dev}/kustomization.yaml` FAIL kustomize build with "wrong node kind: expected ScalarNode but got MappingNode" — the empty-string key `values.services."":` breaks strategic-merge patching. Convert ALL overlay SMP patches to JSON6902 patches using RAW `//` empty-key paths (e.g., `/spec/values/services//scaling/minScale`). EMPIRICAL VALIDATION (Go tests, 2026-09-08): evanphx/json-patch v4 (used by BOTH kustomize CLI and Flux's kustomize lib) applies `//` paths correctly; `~1` escape FAILS in v4; evanphx v5 fails both — so raw `//` is the only form that works everywhere. Keep conditional blocks as JSON6902 `add` ops (paths without empty keys, e.g. `/spec/values/postgres`). The flagger MetricTemplate patch is already JSON6902-style — leave as-is.
  - **E2E MITIGATION DROPPED (scope amendment)**: `scripts/test-template-e2e-local.sh` is PRE-EXISTING BROKEN — it requires `deploy/base/knative-service.yaml` (line 223) which no longer exists after the ksvc-helm-chart migration (base now has helmrelease.yaml), and it deploys via its own OCI-artifact flow that bypasses the template's overlay/HelmRelease path entirely. The SSH switch does NOT change its state. Do NOT fix the e2e in this task (separate effort); document the pre-existing breakage in the notepad instead.
  - Before editing, grep the repo for any OTHER file referencing the HTTPS GitRepository URL and update consistently if the reference would break

  **Must NOT do**:
  - Do NOT change `ref` from branch to tag (Flux tracks `default_branch`; tag semantics documented in Task 7)
  - Do NOT touch `deploy/base/helmrelease.yaml` image fields or values structure (the empty key is the ksvc chart contract)
  - Do NOT use `~1` JSON-pointer escapes in patch paths (empirically broken in evanphx v4)
  - Do NOT fix `scripts/test-template-e2e-local.sh` (pre-existing breakage, out of scope)
  - Do NOT edit any `scripts/dev/*` file

  **Recommended Agent Profile**:
  - **Category**: `quick` — small, precisely-specified edits with grep verification
  - **Skills**: [`git-master`]
    - `git-master`: clean atomic commit discipline for the manifest change + e2e companion change
  - **Skills Evaluated but Omitted**:
    - `fluxcd-setup`: no runtime Flux operations — pure file edits

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 4, 5)
  - **Blocks**: Task 3
  - **Blocked By**: Task 1 (harness defines assertions)

  **References** (CRITICAL - Be Exhaustive):

  **Pattern References** (existing code to follow):
  - `deploy/flux/git-repository.yaml` (entire file, 15 lines) — the file being edited; commented secretRef block at lines 11-13
  - `deploy/overlays/staging/kustomization.yaml` — overlay kustomization structure to mirror for the namespace resource addition
  - `deploy/flux/postgres-kustomization.yaml` — example of a Flux manifest with active secretRef wiring (SOPS age key) for YAML shape reference

  **API/Type References** (contracts to implement against):
  - `source.toolkit.fluxcd.io/v1 GitRepository` — `spec.url` accepts `ssh://git@host/org/repo.git`; `spec.secretRef.name` names the auth secret in the same namespace (flux-system)

  **Test References** (testing patterns to follow):
  - `scripts/test-prod-deploy-static.sh` (Task 1) — the harness assertions this task must satisfy (gitrepository SSH/secretRef, prod namespace, overlay kustomize build)
  - `/tmp/opencode/jsonpatch-test/main4.go` (orchestrator experiment, may be gone) — empirical proof: evanphx v4 applies raw `//` paths; reproduce with the same pattern if re-verification needed

  **External References** (libraries and frameworks):
  - Flux GitRepository auth docs: `https://fluxcd.io/flux/components/source/gitrepositories/#ssh-authentication` — SSH URL shape and secret fields (identity, identity.pub, known_hosts)
  - kustomize JSON6902 transformer source: `https://github.com/kubernetes-sigs/kustomize/blob/master/plugin/builtin/patchjson6902transformer/PatchJson6902Transformer.go` — uses `gopkg.in/evanphx/json-patch.v4` (raw `//` works, `~1` does not)

  **WHY Each Reference Matters**:
  - The target file's commented block tells you exactly where secretRef goes
  - postgres-kustomization.yaml shows the house style for secret references in Flux manifests
  - The JSON6902 empirical validation is the contract for the overlay patch conversion — deviating from raw `//` paths will break CLI kustomize AND Flux

  **Acceptance Criteria**:

  > **AGENT-EXECUTABLE VERIFICATION ONLY**

  - [ ] `grep -A2 'secretRef:' deploy/flux/git-repository.yaml` → shows `name: github-deploy-key` (NOT commented)
  - [ ] `grep 'ssh://git@github.com' deploy/flux/git-repository.yaml` → exactly 1 match
  - [ ] `grep -c 'https://github.com/{{' deploy/flux/git-repository.yaml` → 0
  - [ ] `kustomize build deploy/overlays/prod 2>/dev/null | grep -c 'kind: Namespace'` → ≥ 1 (note: source contains liquid; assertion runs on the generated project via harness)
  - [ ] Generated-project overlay builds GREEN via harness: `PROD_DEPLOY_MATRIX="0,0,0" ./scripts/test-prod-deploy-static.sh` no longer reports "deploy/overlays/prod (kustomize build failed)"
  - [ ] All three overlays converted: `grep -c 'wrong node kind' /dev/null` n/a — instead verify no SMP remains: `grep -c 'apiVersion: helm.toolkit.fluxcd.io' deploy/overlays/prod/kustomization.yaml deploy/overlays/staging/kustomization.yaml deploy/overlays/dev/kustomization.yaml` → 0 in each (SMP patch docs contained apiVersion; JSON6902 ops do not)
  - [ ] Raw `//` paths present: `grep -c 'services//' deploy/overlays/prod/kustomization.yaml` → ≥ 1

  **QA Scenarios (MANDATORY - task is INCOMPLETE without these):**

  ```
  Scenario: secretRef active and URL switched (happy path)
    Tool: Bash
    Preconditions: Task 1 harness exists
    Steps:
      1. Run `grep -A2 'secretRef:' deploy/flux/git-repository.yaml | tee .sisyphus/evidence/task-2-secretref.txt`
      2. Assert output contains `name: github-deploy-key` without leading `#` comment markers
      3. Run `grep 'url:' deploy/flux/git-repository.yaml | tee -a .sisyphus/evidence/task-2-secretref.txt`
      4. Assert URL starts with `ssh://git@github.com/`
    Expected Result: both greps show expected content
    Failure Indicators: secretRef still commented; URL still https
    Evidence: .sisyphus/evidence/task-2-secretref.txt

  Scenario: Production namespace + overlay build green via harness
    Tool: Bash
    Preconditions: Task 1 harness, Task 2 edits applied
    Steps:
      1. Run `PROD_DEPLOY_MATRIX="0,0,0" ./scripts/test-prod-deploy-static.sh 2>&1 | tee .sisyphus/evidence/task-2-harness.txt`
      2. Assert the namespace assertion now passes (output no longer names `production` namespace as missing)
      3. Assert no "deploy/overlays/prod (kustomize build failed)" line remains
    Expected Result: namespace-related assertions green in single combo; overlay builds
    Failure Indicators: harness still reports missing Namespace artifact or overlay build failure
    Evidence: .sisyphus/evidence/task-2-harness.txt

  Scenario: Overlay patch conversion preserves values (edge case)
    Tool: Bash
    Preconditions: generated project available (KEEP_OUTPUT=1 single combo)
    Steps:
      1. Run `KEEP_OUTPUT=1 PROD_DEPLOY_MATRIX="0,0,0" ./scripts/test-prod-deploy-static.sh` and locate the generated dir
      2. Run `kustomize build --load-restrictor LoadRestrictionsNone <gen>/deploy/overlays/prod | grep -E 'minScale|maxScale'`
      3. Assert prod values (minScale: 2, maxScale: 20) present in rendered output — proving the JSON6902 conversion actually applies the patch (not just builds)
      4. Repeat grep for dev overlay (minScale: 0, maxScale: 3)
    Expected Result: rendered output contains the per-env patched values
    Failure Indicators: build succeeds but values remain base defaults (patch silently not applied)
    Evidence: .sisyphus/evidence/task-2-overlay-values.txt
  ```

  **Evidence to Capture:**
  - [ ] task-2-secretref.txt, task-2-harness.txt, task-2-overlay-values.txt

  **Commit**: YES
  - Message: `feat(flux): switch GitRepository to SSH deploy-key auth`
  - Files: `deploy/flux/git-repository.yaml`, `deploy/overlays/prod/namespace.yaml`, `deploy/overlays/prod/kustomization.yaml`, `deploy/overlays/staging/kustomization.yaml`, `deploy/overlays/dev/kustomization.yaml`
  - Pre-commit: harness single-combo run (overlay assertions green)

- [x] 3. `prod-deploy` Target + `scripts/prod/deploy.sh` (Core Orchestration)

  **What to do**:
  - **Makefile additions** (file `Makefile` in repo root — liquid-templated):
    - Vars block: `PROD_KUBECONFIG_PATH := .kubeconfig-prod`, `GITHUB_ORG := {{ github_org }}`, `GITHUB_REPO := {{ github_repo }}`, `GITHUB_REPO_SSH := ssh://git@github.com/{{ github_org }}/{{ github_repo }}.git`
    - Target `prod-deploy`: exports kubeconfig resolution, calls `./scripts/prod/deploy.sh` with `|| { echo "${RED}✗ Failed to deploy to production${NC}"; exit 1; }`, `## doc comment` for help target
    - Target `prod-kubeconfig`: echoes the export line (mirror `dev-kubeconfig`, Makefile:235-237)
    - Target `prod-github-env` placeholder wiring happens in Task 5 — in THIS task only add the vars + `prod-deploy` + `prod-kubeconfig` + help entries
  - **`.gitignore`**: add `.kubeconfig-prod` (next to `.kubeconfig-dev`)
  - **Create `scripts/prod/deploy.sh`** (Gen-1 style: `#!/bin/bash`, `set -euo pipefail`, SCRIPT_DIR/PROJECT_ROOT, ANSI colors, `→/✓/✗`, `[N/M]` step banners). Full flow, in order:
    1. **Kubeconfig resolution**: if `KUBECONFIG` env set → use it; elif `${PROJECT_ROOT}/.kubeconfig-prod` exists → export it; else exit 1 with "Run 'make prod-kubeconfig' / set KUBECONFIG" guidance
    2. **Pre-flights** (fail fast with targeted messages): `kubectl cluster-info` reachable; Flux installed (`kubectl get ns flux-system` + source-controller deployment Running); Knative installed (`kubectl get ns knative-serving`); **Flagger dependency check**: if rendered `deploy/flux/kustomization-prod.yaml` declares `dependsOn` containing `flagger` AND `kubectl get kustomization flagger -n flux-system` fails → exit with "install Flagger operator cluster-wide first" (NEVER auto-install)
    3. **Apply GitRepository**: `kubectl apply --server-side -f deploy/flux/git-repository.yaml` (pattern from Makefile:277)
    4. **Deploy key auto-detection**: `kubectl wait --for=condition=Ready gitrepository/<PROJECT_NAME> -n flux-system --timeout=90s`; on failure, dump `.status.conditions`; if condition message matches auth failure patterns (authentication/permission denied/publickey/invalid credentials — NOT network/DNS errors): check `kubectl get secret github-deploy-key -n flux-system` — if secret exists, print its existing `identity.pub` (DO NOT recreate); if missing, run `flux create secret git github-deploy-key -n flux-system --url "$GITHUB_REPO_SSH"`, extract and print `identity.pub` prominently + exact GitHub instructions (Repo → Settings → Deploy keys → Add deploy key; write access if `enable_image_updates`), then poll GitRepository Ready again up to 5m; if still not Ready → exit 1 with "first run fails by design until the key is added to GitHub" + all diagnostics
    5. **Apply prod Flux config**: `kubectl apply --server-side -k deploy/flux/config/prod`
    6. **Wait for reconciliation**: `kubectl wait --for=condition=Ready kustomization/<PROJECT_NAME>-prod -n flux-system --timeout=5m` (diagnostic dump on failure: `flux get kustomizations` if available, `.status.conditions`); then `kubectl wait --for=condition=Ready helmrelease/<PROJECT_NAME> -n production --timeout=5m` (dump `.status.conditions` + helmrelease yaml on failure)
    7. **Wait for Knative service**: `kubectl wait --for=condition=Ready ksvc/<PROJECT_NAME> -n production --timeout=5m` with the canonical diagnostic dump (ksvc yaml, pod list, last 50 container logs, events) on failure
    8. **Smoke suite (NEW detached-pod pattern)**: extract `SERVICE_URL=$(kubectl get ksvc <PROJECT_NAME> -n production -o jsonpath='{.status.url}')`; run a detached curl pod per check (`kubectl run prod-smoke-<check>-$RANDOM -n production --restart=Never --image=curlimages/curl:8.10.1 -- curl -f -s --max-time 60 <url>`), poll `.status.phase` for `Succeeded|Failed` (timeout 90s), read exit code from `containerStatuses[0].state.terminated.exitCode`, fetch logs, `kubectl delete pod --ignore-not-found`. URL fallback: if the pod phase cycles without terminal state or curl exits with DNS/connect error (7/6/28), retry against `http://<PROJECT_NAME>.production.svc.cluster.local`; allow `SERVICE_URL` make-variable override
    9. **4 smoke assertions** (each records ✓/✗, FAILED counter): `/health/live` → HTTP 200 + body contains `{"status":"alive"}`; `/health/ready` → 200 + `{"status":"ready"}`; `/metrics` → 200 + contains `# HELP`; `/api/v1/hello` → 200 + contains `message`
    10. **Summary**: numbered step echo box, service URL, test results table; exit non-zero if any FAILED
    - Support `--dry-run` flag: prints every planned action (commands with resolved names/URLs) without executing mutating steps; exits 0 after dry-run summary
  - All polling loops bounded with visible countdown/attempt logs; NO interactive prompts anywhere

  **Must NOT do**:
  - Do NOT modify dev targets or `KUBECONFIG_PATH := .kubeconfig-dev`
  - Do NOT build/push images or modify image tags
  - Do NOT apply workloads directly (only GitRepository + `-k deploy/flux/config/prod`)
  - Do NOT auto-install Flagger operator
  - Do NOT use `read -p`/interactive prompts
  - Do NOT use attach-mode `kubectl run --rm -i` (use detached pattern)
  - Do NOT source `common.sh`

  **Recommended Agent Profile**:
  - **Category**: `deep` — the orchestration heart: many failure paths, polls, edge cases, and state machines (auth detect → secret create → poll → retry)
  - **Skills**: [`fluxcd-setup`, `deployment-planning`]
    - `fluxcd-setup`: Flux object semantics, `flux create secret git` behavior (identity/known_hosts fields), condition waiting
    - `deployment-planning`: safe deploy sequencing, pre-flight/rollback discipline
  - **Skills Evaluated but Omitted**:
    - `k8s-microservices-debug`: this task builds a deploy path, not debugs an existing deployment

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Task 6)
  - **Parallel Group**: Wave 3 (with Task 6)
  - **Blocks**: Tasks 6, 7
  - **Blocked By**: Tasks 1, 2

  **References** (CRITICAL - Be Exhaustive):

  **Pattern References** (existing code to follow):
  - `Makefile:245-290` (bootstrap target) — env-var handling idiom, `kubectl apply --server-side` commands, no-op phony pattern; the new targets mirror the recipe style (`@./script.sh || { echo; exit 1; }`)
  - `Makefile:235-237` (dev-kubeconfig) — exact pattern to mirror for `prod-kubeconfig`
  - `scripts/dev/build-and-deploy.sh:130-160` — canonical ksvc wait + diagnostic dump block + URL extraction to replicate
  - `scripts/dev/install-knative.sh:14-22` — KUBECONFIG fallback resolution pattern (`if [[ -z "${KUBECONFIG:-}" ]]`)
  - `scripts/test-template-e2e-local.sh:444+` — existing curl-pod conventions (ADAPT to detached: do NOT copy the attach-mode `--rm -i` invocation)

  **API/Type References** (contracts to implement against):
  - `deploy/base/helmrelease.yaml` — HelmRelease name (`<project-name>`), namespace (`production` via overlay), secrets it references (`<project-name>-secrets`) — needed for wait targets and diagnostics
  - `deploy/flux/kustomization-prod.yaml` — Kustomization name `<project-name>-prod`, `dependsOn` shape (flagger check), wait/timeout fields
  - `src/handlers/health.rs:33-37,62-109,131-148` — exact response bodies the smoke assertions match (`{"status":"alive"}`, `{"status":"ready"}`, `# HELP` metrics, hello `message`)

  **Test References** (testing patterns to follow):
  - `tests/e2e/scripts/06-run-tests.sh:22-34` — `run_test` helper + FAILED counter + summary pattern to mirror in the smoke suite
  - `.github/workflows/template-e2e-test.yaml:798-843` — detached-pod poll/exitCode pattern documentation (kubectl attach race kubernetes#27264)

  **External References** (libraries and frameworks):
  - Flux CLI: `flux create secret git` — `https://fluxcd.io/flux/installation/#bootstrap` and `flux create secret git --help` (creates identity, identity.pub, known_hosts from --url)
  - kubectl wait: `https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#wait`

  **WHY Each Reference Matters**:
  - build-and-deploy.sh diagnostic dump is the house-standard failure UX the new script must replicate
  - install-knative.sh shows how to respect an externally-set KUBECONFIG — the prod script must do the same (GHA sets it implicitly via in-cluster SA)
  - health.rs fixes the exact assertion strings — no guessing about response bodies
  - 06-run-tests.sh gives the repo's own test-runner idiom (counter + summary) so the smoke suite feels native

  **Acceptance Criteria**:

  > **AGENT-EXECUTABLE VERIFICATION ONLY**

  - [ ] `bash -n scripts/prod/deploy.sh` → exit 0
  - [ ] `make -n prod-deploy` → exits 0, prints the script invocation
  - [ ] `make -n prod-kubeconfig` → exits 0, prints an export line containing `.kubeconfig-prod`
  - [ ] `grep -c 'PROD_KUBECONFIG_PATH\|GITHUB_ORG\|GITHUB_REPO_SSH' Makefile` → ≥ 3
  - [ ] `grep -c '\.kubeconfig-prod' .gitignore` → 1
  - [ ] `./scripts/prod/deploy.sh --dry-run` → exit 0; prints all 9 steps + the 4 smoke checks with resolved names; executes zero kubectl mutations (grep dry-run log for `kubectl apply|kubectl run|flux create` → 0 matches outside echo/dry-run banners)
  - [ ] `grep -c 'common.sh' scripts/prod/deploy.sh` → 0
  - [ ] Harness `PROD_DEPLOY_MATRIX="0,0,0"` Makefile-related assertions green

  **QA Scenarios (MANDATORY - task is INCOMPLETE without these):**

  ```
  Scenario: Dry-run full flow (happy path, no cluster)
    Tool: Bash
    Preconditions: Tasks 1-2 done; no KUBECONFIG set
    Steps:
      1. Run `./scripts/prod/deploy.sh --dry-run 2>&1 | tee .sisyphus/evidence/task-3-dryrun.txt`
      2. Assert exit code 0
      3. Assert output contains: "git-repository", "github-deploy-key", "config/prod", "ksvc", "/health/live", "/health/ready", "/metrics", "/api/v1/hello"
      4. Assert output contains no lines beginning with a mutating command actually executed (dry-run banner prefix on all commands)
    Expected Result: exit 0; all 9 steps + 4 checks printed; nothing mutated
    Failure Indicators: exit non-zero; missing step banners; evidence of real kubectl calls
    Evidence: .sisyphus/evidence/task-3-dryrun.txt

  Scenario: Missing kubeconfig fails fast with guidance
    Tool: Bash
    Preconditions: KUBECONFIG unset; .kubeconfig-prod absent
    Steps:
      1. Run `env -u KUBECONFIG ./scripts/prod/deploy.sh 2>&1 | tee .sisyphus/evidence/task-3-nokubeconfig.txt` (NOT --dry-run)
      2. Assert exit code != 0
      3. Assert output mentions `.kubeconfig-prod` or `prod-kubeconfig`
    Expected Result: exit 1 with kubeconfig guidance before any cluster call
    Failure Indicators: proceeds to cluster calls and fails confusingly; interactive prompt
    Evidence: .sisyphus/evidence/task-3-nokubeconfig.txt

  Scenario: Flagger pre-flight fail-fast (flagger-on template variant)
    Tool: Bash
    Preconditions: fake kubectl stub on PATH (cluster-info → ok; get ns flux-system → ok; source-controller get → ok; knative-serving get → ok; get kustomization flagger → exit 1). NOTE: run WITHOUT --dry-run — dry-run must skip cluster pre-flights entirely (no cluster needed, exit 0); this scenario exercises the real flow against the stubbed kubectl.
    Steps:
      1. Create stub kubectl in /tmp/opencode/stub-bin handling the needed subcommands (see Preconditions)
      2. Run `PATH="/tmp/opencode/stub-bin:$PATH" ./scripts/prod/deploy.sh 2>&1 | tee .sisyphus/evidence/task-3-flagger.txt`
      3. Assert output contains "flagger" and "install" guidance and exit code != 0
    Expected Result: fails fast at the flagger pre-flight with actionable message; never proceeds to apply
    Failure Indicators: silently continues; tries to auto-install flagger
    Evidence: .sisyphus/evidence/task-3-flagger.txt
  ```

  > Runtime verification against a real prod cluster (secret creation, reconciliation waits, smoke suite green) is a documented one-time OPERATOR step (Task 7 docs) — automated gates above are the CI-safe equivalent.

  **Evidence to Capture:**
  - [ ] task-3-dryrun.txt, task-3-nokubeconfig.txt, task-3-flagger.txt

  **Commit**: YES
  - Message: `feat(make): add prod-deploy and prod-kubeconfig targets`
  - Files: `Makefile`, `scripts/prod/deploy.sh`, `.gitignore`
  - Pre-commit: `bash -n scripts/prod/deploy.sh && make -n prod-deploy`

- [x] 4. gha-runner RBAC + serviceAccountName

  **What to do**:
  - Create `deploy/infrastructure/gha-runner/rbac.yaml.liquid` (liquid-templated) containing:
    - `ServiceAccount` named `{{ project_name | replace: "_", "-" }}-runner` in namespace `actions-runner-system`
    - `Role` + `RoleBinding` in namespace `flux-system` (binding subject references the SA with `namespace: actions-runner-system`) granting:
      - `gitrepositories`, `helmreleases`, `kustomizations` (`source.toolkit.fluxcd.io`, `helm.toolkit.fluxcd.io`, `kustomize.toolkit.fluxcd.io` groups): get/list/watch/create/update/patch — for apply + wait steps
      - `helmcharts.source.toolkit.fluxcd.io`: get/list/watch (harmless unconditional — needed by wait steps)
      - `secrets`: get/list/create/update/patch (deploy key creation)
      - Conditional block `{% if enable_image_updates %}`: `imagerepositories`, `imagepolicies`, `imageupdateautomations` (`image.toolkit.fluxcd.io`): get/list/watch/create/update/patch `{% endif %}`
    - `Role` + `RoleBinding` in namespace `production` granting: `ksvc`/`services.serving.knative.dev`: get/list/watch; `pods`: create/delete/get/list; `pods/log`: get; `events`: get (smoke-test pod lifecycle + diagnostics)
  - Edit `deploy/infrastructure/gha-runner/kustomization.yaml`: add `rbac.yaml` to resources — MUST be listed BEFORE `helmrelease.yaml` (SA must exist before the scale set references it)
  - Edit `deploy/infrastructure/gha-runner/helmrelease.yaml`: add `serviceAccountName: {{ project_name | replace: "_", "-" }}-runner` under `values.template.spec` (adjacent to `priorityClassName`, line ~54)

  **Must NOT do**:
  - Do NOT grant cluster-wide ClusterRole/ClusterRoleBinding (namespace-scoped only)
  - Do NOT grant secret READ beyond flux-system needs, and do NOT grant secrets in production
  - Do NOT touch runner resource limits, priority class, or dind config

  **Recommended Agent Profile**:
  - **Category**: `quick` — one templated YAML file + two small edits, fully specified above
  - **Skills**: [`k8s-microservices-debug`]
    - `k8s-microservices-debug`: RBAC verb/kind mapping correctness is the core risk here
  - **Skills Evaluated but Omitted**:
    - `fluxcd-setup`: the RBAC file is static config; no Flux operations

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 2, 5)
  - **Blocks**: Task 7
  - **Blocked By**: Task 1

  **References** (CRITICAL - Be Exhaustive):

  **Pattern References** (existing code to follow):
  - `deploy/infrastructure/gha-runner/kustomization.yaml` — current resources list (oci-repository.yaml, helmrelease.yaml) to extend with rbac.yaml FIRST
  - `deploy/infrastructure/gha-runner/helmrelease.yaml:52-54` — `template.spec` block where `serviceAccountName` is added (next to priorityClassName)
  - `deploy/infrastructure/flagger/operator/namespace.yaml` — house style for namespace-scoped RBAC-ish manifests (labels, apiVersion conventions)

  **API/Type References** (contracts to implement against):
  - `deploy/flux/config/prod/kustomization.yaml:6` — confirms the gha-runner kustomization rides the prod config apply (RBAC lands with it)
  - `deploy/flux/image-repository.yaml` + `deploy/flux/image-policy.yaml` + `deploy/flux/image-update-automation.yaml` — the image CR kinds the conditional `{% if enable_image_updates %}` block must cover
  - Knative serving API group: `serving.knative.dev` (ksvc kind) for the production Role

  **Test References** (testing patterns to follow):
  - `scripts/test-prod-deploy-static.sh` (Task 1) — the kustomize-build + grep assertions that verify this file renders correctly (incl. RoleBinding subject namespace check)

  **External References** (libraries and frameworks):
  - Kubernetes RBAC docs: `https://kubernetes.io/docs/reference/access-authn-authz/rbac/` — Role vs ClusterRole, subjects namespace semantics
  - ARC kubernetes mode: `https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller` — runner pod template inherits serviceAccountName

  **WHY Each Reference Matters**:
  - The conditional image-CR block prevents 403s when `enable_image_updates` is on (Metis Gap 4) — the exact CR kinds come from deploy/flux/image-*.yaml
  - Subject namespace must be `actions-runner-system` because ARC creates runner pods there — a wrong namespace silently breaks the binding
  - Resource ordering in kustomization.yaml matters: SA before helmrelease avoids a race where the scale set references a missing SA

  **Acceptance Criteria**:

  > **AGENT-EXECUTABLE VERIFICATION ONLY**

  - [ ] `kustomize build deploy/infrastructure/gha-runner` (on a generated project) exits 0 with no `{%` residue — verified via harness
  - [ ] Rendered output contains exactly: 1 `kind: ServiceAccount`, 2 `kind: Role`, 2 `kind: RoleBinding`
  - [ ] Both RoleBinding `subjects[].namespace` values equal `actions-runner-system`
  - [ ] `grep -c 'serviceAccountName' deploy/infrastructure/gha-runner/helmrelease.yaml` → ≥ 1
  - [ ] With `enable_image_updates` ON combo: rendered flux-system Role contains `imageupdateautomations`; with OFF: absent
  - [ ] `grep -c 'ClusterRole' deploy/infrastructure/gha-runner/rbac.yaml.liquid` → 0

  **QA Scenarios (MANDATORY - task is INCOMPLETE without these):**

  ```
  Scenario: RBAC renders with SA + both RoleBindings (happy path)
    Tool: Bash
    Preconditions: Task 1 harness; Tasks 2 edits
    Steps:
      1. Run `PROD_DEPLOY_MATRIX="0,0,0" ./scripts/test-prod-deploy-static.sh 2>&1 | tee .sisyphus/evidence/task-4-rbac.txt`
      2. Assert gha-runner kustomize assertions pass (SA=1, RoleBinding=2, subject namespace check)
    Expected Result: all RBAC assertions green in single combo
    Failure Indicators: build fails on rbac.yaml.liquid; liquid residue; wrong subject namespace
    Evidence: .sisyphus/evidence/task-4-rbac.txt

  Scenario: Conditional image CR rules toggle correctly (edge case)
    Tool: Bash
    Preconditions: harness matrix
    Steps:
      1. Run harness with image_updates OFF combo (`PROD_DEPLOY_MATRIX="0,0,0"`) → assert rendered Role does NOT contain `imageupdateautomations`
      2. Run harness with image_updates ON combo (`PROD_DEPLOY_MATRIX="0,1,0"`) → assert rendered Role DOES contain `imageupdateautomations`
      3. Save both outputs
    Expected Result: conditional block flips correctly between combos
    Failure Indicators: image rules present when flag off (would break public-repo combos); absent when flag on (403 at runtime)
    Evidence: .sisyphus/evidence/task-4-rbac-toggle.txt
  ```

  **Evidence to Capture:**
  - [ ] task-4-rbac.txt, task-4-rbac-toggle.txt

  **Commit**: YES
  - Message: `feat(gha-runner): add runner ServiceAccount and RBAC`
  - Files: `deploy/infrastructure/gha-runner/rbac.yaml.liquid`, `deploy/infrastructure/gha-runner/kustomization.yaml`, `deploy/infrastructure/gha-runner/helmrelease.yaml`
  - Pre-commit: `kustomize build deploy/infrastructure/gha-runner` (template repo check: skip if file contains liquid in this repo context; harness is the authoritative check)

- [x] 5. `prod-github-env` Setup Target

  **What to do**:
  - Create `scripts/prod/create-github-env.sh` (Gen-1 style, `#!/usr/bin/env bash` or match Gen-1 `#!/bin/bash`, `set -euo pipefail`, colors, no `common.sh`):
    1. **Auth check**: `gh auth status` — fail fast with "run `gh auth login` with admin access" if unavailable
    2. **Repo slug**: use baked-in `GITHUB_ORG`/`GITHUB_REPO` (passed from Makefile vars; do NOT derive from `git remote get-url` — forks/SSH remotes make it fragile)
    3. **Create environment**: `gh api -X POST /repos/{org}/{repo}/environments/production -f deployment_branch_policy[protected_branches]=false -F deployment_branch_policy[custom_branch_policies]=true`; treat HTTP 409/422 "already exists" as idempotent success (GET first to check)
    4. **Branch policies**: `gh api -X POST /repos/{org}/{repo}/environments/production/deployment-branch-policies -f name=main` and `-f name=v*`; if the API rejects the `v*` pattern (validate Metis assumption A6), print a graceful error advising to add tag patterns manually in repo settings, and continue with the `main` policy only (do not abort the whole setup)
    5. **Print next steps**: how to add environment secrets if needed (`PROD_KUBECONFIG` for the non-ARC path), where to find the environment in repo settings, reminder that `environment: production` gates the deploy workflow
  - **Makefile**: add `prod-github-env` target calling `./scripts/prod/create-github-env.sh || { echo "${RED}✗ Failed to create GitHub environment${NC}"; exit 1; }` with `## doc comment`
  - Support `--dry-run` flag printing all planned `gh api` calls without executing

  **Must NOT do**:
  - Do NOT set required reviewers (branch policy only per interview decision)
  - Do NOT create environment secrets automatically (kubeconfig content is operator-provided; print instructions only)
  - Do NOT call this script from any workflow (CI tokens cannot create environments — local-only tool)

  **Recommended Agent Profile**:
  - **Category**: `quick` — small script, single API surface, idempotency logic specified
  - **Skills**: [] — plain `gh api` usage; no domain skill adds value (loading skills would be noise)
  - **Skills Evaluated but Omitted**:
    - `fluxcd-setup`: no Flux involvement
    - `test-gen`: static greps suffice for this scope

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 2, 4)
  - **Blocks**: Task 7
  - **Blocked By**: Task 1 (harness assertions)

  **References** (CRITICAL - Be Exhaustive):

  **Pattern References** (existing code to follow):
  - `scripts/setup-github-runners.sh:24-46` — house color/log helper style for GitHub-automation scripts (closest sibling script)
  - `Makefile:252-290` — target recipe style (`@./script.sh || { echo; exit 1; }` + `## doc`)

  **API/Type References** (contracts to implement against):
  - GitHub REST: `POST /repos/{owner}/{repo}/environments/{environment_name}` with `deployment_branch_policy` object; `POST /repos/{owner}/{repo}/environments/{environment_name}/deployment-branch-policies` with `name`
  - `gh api` CLI: `-X POST`, `-f`/`-F` field passing, exit codes on HTTP errors

  **Test References** (testing patterns to follow):
  - `scripts/test-prod-deploy-static.sh` (Task 1) — grep assertions for target + script presence

  **External References** (libraries and frameworks):
  - GitHub Environments REST: `https://docs.github.com/en/rest/deployments/environments` — create environment + branch policies endpoints, response codes

  **WHY Each Reference Matters**:
  - setup-github-runners.sh is the only existing script touching the GitHub API — mirror its error/UX conventions
  - The idempotency contract (409/422 → success) makes repeated runs safe, matching the deploy-side idempotency principle

  **Acceptance Criteria**:

  > **AGENT-EXECUTABLE VERIFICATION ONLY**

  - [ ] `bash -n scripts/prod/create-github-env.sh` → exit 0
  - [ ] `make -n prod-github-env` → exit 0
  - [ ] `./scripts/prod/create-github-env.sh --dry-run` → exit 0, prints the environment + branch-policy API calls with resolved org/repo, executes no `gh api`
  - [ ] `grep -c 'deployment-branch-policies' scripts/prod/create-github-env.sh` → ≥ 1
  - [ ] `grep -c 'read -p' scripts/prod/create-github-env.sh` → 0

  **QA Scenarios (MANDATORY - task is INCOMPLETE without these):**

  ```
  Scenario: Dry-run prints planned API calls (happy path)
    Tool: Bash
    Preconditions: gh CLI may or may not be installed
    Steps:
      1. Run `./scripts/prod/create-github-env.sh --dry-run 2>&1 | tee .sisyphus/evidence/task-5-dryrun.txt`
      2. Assert exit 0 and output contains "environments/production" and "deployment-branch-policies" and "main" and "v*"
    Expected Result: exit 0; all planned calls printed; no network calls made
    Failure Indicators: attempts real gh api calls; missing branch policy lines
    Evidence: .sisyphus/evidence/task-5-dryrun.txt

  Scenario: Missing gh auth fails fast (failure path)
    Tool: Bash
    Preconditions: stub gh on PATH whose `auth status` exits 1 (or gh absent)
    Steps:
      1. Run `PATH="/tmp/opencode/stub-bin-noauth:$PATH" ./scripts/prod/create-github-env.sh 2>&1 | tee .sisyphus/evidence/task-5-noauth.txt`
      2. Assert exit code != 0 and output contains "gh auth login" guidance
    Expected Result: fail-fast with actionable message before any API call
    Failure Indicators: proceeds to API calls and fails with confusing auth error
    Evidence: .sisyphus/evidence/task-5-noauth.txt
  ```

  **Evidence to Capture:**
  - [ ] task-5-dryrun.txt, task-5-noauth.txt

  **Commit**: YES
  - Message: `feat(make): add prod-github-env setup target`
  - Files: `scripts/prod/create-github-env.sh`, `Makefile`
  - Pre-commit: `bash -n scripts/prod/create-github-env.sh && make -n prod-github-env`

- [x] 6. GitHub Actions Deploy Workflow (`deploy.yaml.liquid`)

  **What to do**:
  - Create `.github/workflows/deploy.yaml.liquid` (liquid-templated like ci.yaml.liquid):
    - **Name**: `Deploy Production`
    - **Triggers**: `push: tags: ['v*']` + `workflow_dispatch` (manual deploy button)
    - **Permissions**: `contents: read` only
    - **Concurrency**: group `{% raw %}${{ github.ref }}{% endraw %}`-based (e.g., `prod-deploy-{% raw %}${{ github.ref }}{% endraw %}`), `cancel-in-progress: false` (queue deploys, never cancel mid-deploy)
    - **Environment**: `environment: production` on the deploy job
    - **runs-on**: follows ci.yaml.liquid:20 convention — `{% if feature_gha_runner %}{{ project_name | replace: "_", "-" }}-runner{% else %}ubuntu-latest{% endif %}`
    - **Timeout**: `timeout-minutes: 45`
    - **Steps**:
      1. `actions/checkout@v6`
      2. Install pinned kubectl + flux CLI (exact versions as env vars at workflow top, e.g., `KUBECTL_VERSION: v1.31.4`, `FLUX_VERSION: v2.4.0` — pin to current stable; NO `@latest`); install via curl to `/usr/local/bin` (ARC runner) — non-ARC path same steps
      3. Non-ARC path ONLY (`{% if not feature_gha_runner %}`): write `{% raw %}${{ secrets.PROD_KUBECONFIG }}{% endraw %}` to `${{ github.workspace }}/.kubeconfig-prod` with 0600 perms, export KUBECONFIG; if secret empty → fail fast with "set the PROD_KUBECONFIG Actions secret in the production environment" `{% endif %}`
      4. Echo clarification: "Flux deploys default_branch + image automation tags — a tag push triggers deployment of the current main ref, not the tag itself"
      5. Run `make prod-deploy`
      6. Upload smoke-suite diagnostics on failure (`if: failure()` — capture deploy.sh output + kubectl dumps)
  - Keep workflow minimal — it delegates ALL deploy logic to the make target

  **Must NOT do**:
  - Do NOT build/push images (release workflow owns that)
  - Do NOT call `prod-github-env`
  - Do NOT hardcode kubeconfig content or echo secrets
  - Do NOT use floating versions (`@latest`, unpinned curl URLs)
  - Do NOT add lint/test jobs (ci.yaml.liquid owns those)

  **Recommended Agent Profile**:
  - **Category**: `quick` — single templated YAML against a precise spec
  - **Skills**: [`ci-cd`]
    - `ci-cd`: GitHub Actions workflow structure/conventions overlap directly
  - **Skills Evaluated but Omitted**:
    - `fluxcd-setup`: workflow only invokes make; no Flux operations

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 3 (with Task 3)
  - **Blocks**: Task 7
  - **Blocked By**: Tasks 1, 3 (target name it calls must exist)

  **References** (CRITICAL - Be Exhaustive):

  **Pattern References** (existing code to follow):
  - `.github/workflows/ci.yaml.liquid` (entire file, 219 lines) — liquid idiom reference: `{% raw %}` escaping for GH expressions, feature conditionals, runs-on line 20, env block style
  - `.github/workflows/template-e2e-test.yaml:730-753,771-789` — Flux/ksvc wait step shapes (what make prod-deploy replicates internally; informs step naming/comment style)
  - `.github/workflows/release.yaml.liquid` — the other templated workflow; naming/versioning conventions (how it pins versions)

  **API/Type References** (contracts to implement against):
  - `Makefile` (post-Task-3): `prod-deploy` target name + expected env (`KUBECONFIG` respected by the script)
  - GitHub workflow schema: `environment`, `concurrency`, `permissions`, `timeout-minutes` keys

  **Test References** (testing patterns to follow):
  - `scripts/test-prod-deploy-static.sh` (Task 1) — the YAML parse + grep assertions verifying this file

  **External References** (libraries and frameworks):
  - GitHub Actions: environments `https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment`
  - actions/checkout: `https://github.com/actions/checkout` (v6 in use per ci.yaml.liquid)
  - flux CLI install: `https://fluxcd.io/flux/installation/#install-the-flux-cli` (download URL shape for pinned versions)

  **WHY Each Reference Matters**:
  - ci.yaml.liquid is the canonical liquid-workflow file — copy its `{% raw %}` handling or the generated workflow will contain raw liquid in GH expressions
  - The concurrency/permissions/timeout requirements came from Metis guardrails — absent them, concurrent deploys race and tokens are over-privileged

  **Acceptance Criteria**:

  > **AGENT-EXECUTABLE VERIFICATION ONLY**

  - [ ] Rendered workflow (generated project) parses via `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/deploy.yaml'))"` — verified via harness
  - [ ] grep assertions on rendered file: `environment: production` present; `runs-on:` line matches the conditional convention; `concurrency:` present with `cancel-in-progress: false`; `permissions:` contains `contents: read`; `timeout-minutes: 45`; `make prod-deploy` invoked; tool version pins present; NO `{% raw %}` residue leaking into rendered output
  - [ ] Template-repo check: file is valid liquid (no unbalanced `{% if %}`)

  **QA Scenarios (MANDATORY - task is INCOMPLETE without these):**

  ```
  Scenario: Rendered workflow parses and contains required keys (happy path)
    Tool: Bash
    Preconditions: Task 1 harness; Task 3 complete
    Steps:
      1. Run `PROD_DEPLOY_MATRIX="0,0,0" ./scripts/test-prod-deploy-static.sh 2>&1 | tee .sisyphus/evidence/task-6-workflow.txt`
      2. Assert workflow assertions green (yaml parse, environment, concurrency, permissions, timeout, make prod-deploy)
    Expected Result: all workflow assertions pass in single combo
    Failure Indicators: yaml parse error; missing keys; liquid residue
    Evidence: .sisyphus/evidence/task-6-workflow.txt

  Scenario: Non-ARC path includes kubeconfig secret fallback (edge case)
    Tool: Bash
    Preconditions: harness with feature_gha_runner OFF
    Steps:
      1. Run harness combo `PROD_DEPLOY_MATRIX="0,0,0"` (gha off) → assert rendered workflow contains `secrets.PROD_KUBECONFIG` and the fail-fast message
      2. Run harness combo with gha ON (`PROD_DEPLOY_MATRIX="1,0,0"`) → assert `secrets.PROD_KUBECONFIG` is ABSENT and runs-on is `<project>-runner`
    Expected Result: conditional paths flip correctly
    Failure Indicators: kubeconfig secret referenced on ARC path (in-cluster SA already provides auth); missing runner name on ARC path
    Evidence: .sisyphus/evidence/task-6-workflow-toggle.txt
  ```

  **Evidence to Capture:**
  - [ ] task-6-workflow.txt, task-6-workflow-toggle.txt

  **Commit**: YES
  - Message: `feat(ci): add production deploy workflow`
  - Files: `.github/workflows/deploy.yaml.liquid`
  - Pre-commit: harness workflow assertions (template-repo-only sanity: liquid balance check)

- [x] 7. Documentation

  **What to do**:
  - Add a focused section to `docs/DEPLOYMENT.md` (it already exists — extend, do not rewrite): "Production Deployment"
    - Prerequisites: prod cluster with Flux + Knative installed; local tooling (`kubectl`, `flux` CLI, `gh` for env setup); kubeconfig access (env var or `.kubeconfig-prod`)
    - One-time setup: `make prod-github-env` (GitHub environment + branch policies); deploy key flow explanation (first run creates the key and prints the pubkey — deploy fails by design until the key is added to GitHub at Repo → Settings → Deploy keys; second run succeeds; write access needed if `enable_image_updates`)
    - Usage: `make prod-deploy` (local), GHA deploy via tag push `v*` or the Actions UI (workflow_dispatch, `production` environment)
    - **Semantics note**: Flux tracks `default_branch` — a tag push triggers deployment of the current main ref + whatever image tag ImagePolicy selected; tags do NOT pin the deployed ref
    - Kubeconfig options: `KUBECONFIG` env var → `.kubeconfig-prod` file; ARC runner path needs neither (in-cluster SA)
    - Security note: the runner ServiceAccount can read the deploy-key secret in flux-system (acceptable for a per-repo runner; scoped to 2 namespaces only, no cluster-wide RBAC)
    - Rollback story: git revert + Flux reconciles (no tooling built — one paragraph)
  - Add a short pointer in `README.md.liquid` (deploy section) linking to the new docs section

  **Must NOT do**:
  - Do NOT rewrite existing DEPLOYMENT.md sections
  - Do NOT create new top-level docs files
  - Do NOT document the `common.sh` bug or dev-script internals
  - No placeholder/TODO text

  **Recommended Agent Profile**:
  - **Category**: `writing` — prose documentation
  - **Skills**: [`document`]
    - `document`: docs structure/consistency conventions
  - **Skills Evaluated but Omitted**:
    - all others: no code changes

  **Parallelization**:
  - **Can Run In Parallel**: NO (sequential after features)
  - **Parallel Group**: Wave 4 (alone)
  - **Blocks**: Task 8
  - **Blocked By**: Tasks 2, 3, 4, 5, 6 (documents what actually shipped)

  **References** (CRITICAL - Be Exhaustive):

  **Pattern References** (existing code to follow):
  - `docs/DEPLOYMENT.md` — existing structure/tone; line ~104 recommends `flux bootstrap github` — the new section complements (not contradicts) it
  - `README.md.liquid` — where the deploy section pointer goes (find the dev/deploy docs section)
  - `docs/FLAGGER.md` "Prerequisites" style — example of focused prerequisite documentation house style

  **API/Type References** (contracts to implement against):
  - `Makefile` (post-Tasks-3/5) — exact target names (`prod-deploy`, `prod-github-env`, `prod-kubeconfig`) documented
  - `scripts/prod/deploy.sh` (post-Task-3) — actual flags (`--dry-run`) and behaviors documented (first-run-fails-by-design)

  **Test References** (testing patterns to follow):
  - n/a (docs only)

  **External References** (libraries and frameworks):
  - GitHub deploy keys: `https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys` — read-only vs write access semantics for the docs security note

  **WHY Each Reference Matters**:
  - DEPLOYMENT.md:104 already documents `flux bootstrap` — the new section must reference it as the alternative path so docs stay coherent
  - The semantics note (tag ≠ deployed ref) prevents the most common user misunderstanding of the GHA trigger

  **Acceptance Criteria**:

  > **AGENT-EXECUTABLE VERIFICATION ONLY**

  - [ ] `grep -c 'prod-deploy' docs/DEPLOYMENT.md` → ≥ 3
  - [ ] `grep -c 'prod-github-env' docs/DEPLOYMENT.md` → ≥ 1
  - [ ] `grep -c 'deploy key' docs/DEPLOYMENT.md` → ≥ 1 (case-insensitive)
  - [ ] `grep -c 'TODO\|PLACEHOLDER\|FIXME' docs/DEPLOYMENT.md` → 0 in the new section
  - [ ] `grep -c 'prod-deploy' README.md.liquid` → ≥ 1

  **QA Scenarios (MANDATORY - task is INCOMPLETE without these):**

  ```
  Scenario: Docs section complete (happy path)
    Tool: Bash
    Steps:
      1. Run `grep -n '## Production Deployment' docs/DEPLOYMENT.md | tee .sisyphus/evidence/task-7-docs.txt`
      2. Assert section exists
      3. Run the four grep counts above; assert all thresholds met
    Expected Result: section present; all keyword counts met; no placeholders
    Failure Indicators: missing section; counts below thresholds; TODO markers
    Evidence: .sisyphus/evidence/task-7-docs.txt
  ```

  **Evidence to Capture:**
  - [ ] task-7-docs.txt

  **Commit**: YES
  - Message: `docs: document production deployment workflow`
  - Files: `docs/DEPLOYMENT.md`, `README.md.liquid`
  - Pre-commit: n/a (docs)

- [x] 8. Final Validation Sweep

  **What to do**:
  - Run `scripts/test-prod-deploy-static.sh` across the FULL flag matrix (all 8 combos; no PROD_DEPLOY_MATRIX override)
  - `bash -n` on all new/changed scripts; `make -n prod-deploy` + `make -n prod-github-env` + `make help` (verify new targets listed)
  - Verify dev e2e path unaffected: re-read the e2e mitigation from Task 2 and confirm `bash -n scripts/test-template-e2e-local.sh` + the override grep still pass; confirm `make bootstrap` Makefile lines untouched (git diff scope check)
  - Diff review for scope creep: `git log --oneline` + `git diff <start>..HEAD --stat` — every changed file must map to a plan task; flag unaccounted changes
  - Verify liquid residue: run each kustomize build from the harness manually and `grep -r '{%'` on outputs → 0 matches
  - Verify the commit series matches the Commit Strategy (7 commits, Conventional Commits, correct order)

  **Must NOT do**:
  - Do NOT fix issues directly — this is a verification gate; failures go back to the owning task
  - Do NOT run against any cluster

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high` — cross-cutting verification and judgment
  - **Skills**: [`review`]
    - `review`: final review pass conventions
  - **Skills Evaluated but Omitted**:
    - `review-work`: overkill for this size — single reviewer suffices

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 5 (alone, after Task 7)
  - **Blocks**: Final Verification Wave (F1-F4)
  - **Blocked By**: Task 7

  **References** (CRITICAL - Be Exhaustive):

  **Pattern References** (existing code to follow):
  - All files produced by Tasks 1-7 (the review subject)
  - `git log --oneline -10` — commit series verification

  **Test References** (testing patterns to follow):
  - `scripts/test-prod-deploy-static.sh` — the authoritative gate

  **External References** (libraries and frameworks):
  - Conventional Commits: `https://www.conventionalcommits.org/` — commit message verification

  **WHY Each Reference Matters**:
  - The full-matrix harness run is the single strongest automated gate this feature has — it catches cross-feature-flag rendering bugs that single-combo runs miss

  **Acceptance Criteria**:

  > **AGENT-EXECUTABLE VERIFICATION ONLY**

  - [ ] `./scripts/test-prod-deploy-static.sh` (full matrix) → exit 0, all 8 combos green
  - [ ] `make help` output contains `prod-deploy`, `prod-github-env`, `prod-kubeconfig`
  - [ ] Zero `{%` residue in all kustomize build outputs
  - [ ] `git log --oneline` shows the 7-commit series in Commit Strategy order, all Conventional Commits
  - [ ] `git diff <pre-work-SHA>..HEAD --stat` — every file maps to a plan task

  **QA Scenarios (MANDATORY - task is INCOMPLETE without these):**

  ```
  Scenario: Full matrix harness green (happy path)
    Tool: Bash
    Steps:
      1. Run `./scripts/test-prod-deploy-static.sh 2>&1 | tee .sisyphus/evidence/task-8-matrix.txt`
      2. Assert exit 0; assert output shows 8 combos all passing
    Expected Result: exit 0; 8/8 combos green
    Failure Indicators: any combo fails; fewer than 8 combos ran
    Evidence: .sisyphus/evidence/task-8-matrix.txt

  Scenario: Scope fidelity diff review (failure detection)
    Tool: Bash
    Steps:
      1. Run `git diff $(git rev-list HEAD -n 8 | tail -1)..HEAD --stat | tee .sisyphus/evidence/task-8-diffstat.txt`
      2. Cross-check every listed file against the plan's task file lists
      3. Assert no file outside the plan's declared file lists appears
    Expected Result: every changed file accounted for by a task
    Failure Indicators: orphan files; unexpected edits to dev targets or common.sh fixes
    Evidence: .sisyphus/evidence/task-8-diffstat.txt
  ```

  **Evidence to Capture:**
  - [ ] task-8-matrix.txt, task-8-diffstat.txt

  **Commit**: NO (verification only — no changes expected; if a fix is needed it goes back to the owning task)

---

## Final Verification Wave (MANDATORY — after ALL implementation tasks)

> 4 review agents run in PARALLEL. ALL must APPROVE. Present consolidated results to user and get explicit "okay" before completing.
>
> **Do NOT auto-proceed after verification. Wait for user's explicit approval before marking work complete.**
> **Never mark F1-F4 as checked before getting user's okay.** Rejection or user feedback -> fix -> re-run -> present again -> wait for okay.

- [x] F1. **Plan Compliance Audit** — `oracle`
  Read the plan end-to-end. For each "Must Have": verify implementation exists (read file, run command). For each "Must NOT Have": search codebase for forbidden patterns — reject with file:line if found. Check evidence files exist in .sisyphus/evidence/. Compare deliverables against plan.
  Output: `Must Have [N/N] | Must NOT Have [N/N] | Tasks [N/N] | VERDICT: APPROVE/REJECT`

- [x] F2. **Code Quality Review** — `unspecified-high`
  `bash -n` all scripts; shellcheck if available; review all changed files for: unused vars, unquoted expansions, missing `set -euo pipefail`, `@latest` pins, missing error handling on kubectl/gh calls, AI slop (excessive comments, generic names). Check liquid files render cleanly (no stray `{%`).
  Output: `Syntax [PASS/FAIL] | Lint [PASS/FAIL/N-A] | Files [N clean/N issues] | VERDICT`

- [x] F3. **Real QA Execution** — `unspecified-high`
  Start from clean state. Execute EVERY QA scenario from EVERY task — follow exact steps, capture evidence. Run the harness across the full flag matrix. Save to `.sisyphus/evidence/final-qa/`.
  Output: `Scenarios [N/N pass] | Harness [matrix results] | Edge Cases [N tested] | VERDICT`

- [x] F4. **Scope Fidelity Check** — `deep`
  For each task: read "What to do", read actual diff (git log/diff). Verify 1:1 — everything in spec was built (no missing), nothing beyond spec was built (no creep). Check "Must NOT do" compliance. Detect cross-task contamination. Flag unaccounted changes.
  Output: `Tasks [N/N compliant] | Contamination [CLEAN/N issues] | Unaccounted [CLEAN/N files] | VERDICT`

---

## Commit Strategy

1. `test(prod): add static validation harness for prod deployment tooling` — scripts/test-prod-deploy-static.sh (red)
2. `feat(flux): switch GitRepository to SSH deploy-key auth` — deploy/flux/git-repository.yaml + deploy/overlays/prod/namespace.yaml + e2e mitigation
3. `feat(gha-runner): add runner ServiceAccount and RBAC` — deploy/infrastructure/gha-runner/*
4. `feat(make): add prod-deploy and prod-kubeconfig targets` — Makefile + scripts/prod/deploy.sh + .gitignore
5. `feat(make): add prod-github-env setup target` — scripts/prod/create-github-env.sh + Makefile
6. `feat(ci): add production deploy workflow` — .github/workflows/deploy.yaml.liquid
7. `docs: document production deployment workflow` — docs/DEPLOYMENT.md + README pointer

Harness goes green progressively across commits 2-6. No fixup commits; fix forward.

---

## Success Criteria

### Verification Commands
```bash
bash -n scripts/prod/deploy.sh scripts/prod/create-github-env.sh scripts/test-prod-deploy-static.sh   # Expected: exit 0, no output
make -n prod-deploy                                                                                    # Expected: dry-run prints steps, exit 0
make -n prod-github-env                                                                                # Expected: dry-run prints steps, exit 0
./scripts/test-prod-deploy-static.sh                                                                   # Expected: PASS across full flag matrix, exit 0
kustomize build deploy/overlays/prod | grep -c 'namespace: production'                                 # Expected: >= 1
kustomize build deploy/infrastructure/gha-runner | grep -c 'kind: RoleBinding'                         # Expected: 2
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/deploy.yaml'))"                        # Expected: exit 0 (rendered file)
grep -A2 'secretRef:' deploy/flux/git-repository.yaml                                                  # Expected: name: github-deploy-key
grep 'ssh://git@github.com' deploy/flux/git-repository.yaml                                            # Expected: 1 match
```

### Final Checklist
- [ ] All "Must Have" present
- [ ] All "Must NOT Have" absent
- [ ] Harness green across flag matrix
- [ ] Dev flow unaffected (bootstrap + dev e2e)
