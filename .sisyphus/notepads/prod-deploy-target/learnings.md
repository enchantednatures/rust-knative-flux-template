# Learnings — prod-deploy-target

## 2026-09-08 Session Start
- Repo is a cargo-generate TEMPLATE: Makefile (plain name, liquid vars inside), scripts/dev/build-and-deploy.sh has baked-in liquid names
- Gen-1 script style: #!/bin/bash, set -euo pipefail, SCRIPT_DIR/PROJECT_ROOT derivation, ANSI colors, →/✓/✗ echoes
- KNOWN BUG (out of scope): scripts/dev/{deploy-postgres,check-postgres-status,port-forward-postgres}.sh source non-existent common.sh — new scripts must NOT source it
- Canonical wait: kubectl wait --for=condition=Ready ksvc/<name> -n <ns> --timeout=5m + diagnostic dump
- Existing kubectl_curl (scripts/test-template-e2e-local.sh:444-445) is ATTACH-mode — detached-pod pattern is NEW code
- ci.yaml.liquid:20 runs-on conditional convention: {% if feature_gha_runner %}<name>-runner{% else %}ubuntu-latest{% endif %}
- e2e harness generates with github_org = "test-org" (fictional) — SSH switch needs post-generation override
- Prod overlay namespace: production; HelmRelease name = <project-name>; Kustomization name = <project-name>-prod

## 2026-09-08 Task 1 (static harness)
- cargo-generate 0.23.8 has NO `--defaults` flag; `-s/--silent` requires ALL placeholders supplied via --values-file (missing value = generation failure)
- `--define` bool coercion WORKS but only accepts literal `true`/`false` — "0"/"1" fails with "provided string was not `true` or `false`"; harness maps matrix 0/1 → true/false
- `--define` values take precedence over --values-file entries (verified: gha-runner dir appears with define=true over file=false)
- WITHOUT --allow-commands: post-generate.rhai hook still RUNS but its system::command calls (clippy --fix / cargo fmt) are blocked → caught as non-blocking warnings; generation exits 0 fast. Safe for 8-combo loops
- `--destination` dir must EXIST before cargo generate (mkdir -p first) — non-existent dir = exit 1
- `cargo generate --path` inside a git repo reads the git INDEX, not the working tree → harness copies template to temp dir without .git/ (matrix-script pattern); also excludes .opencode/.sisyphus (ignored anyway, big speedup)
- `kustomize build deploy/flux/config/prod` REQUIRES `--load-restrictor LoadRestrictionsNone` (references ../../kustomization-prod.yaml outside build root); repo e2e script uses same flag; kubectl kustomize supports the flag too
- kustomize 5.8.1 + kubectl-bundled both FAIL `kustomize build deploy/overlays/prod` (and dev!) with "wrong node kind: expected ScalarNode but got MappingNode" — pre-existing SMP patch issue on `values.services."":` (see issues.md)
- Red-state QA verified: exit 1, 8/8 combos fail naming artifact+combo; keywords prod-deploy/git-repository/production present; failure counts scale with flags (13→15→16)

## 2026-09-08 Orchestrator verification of Task 1 + blocker investigation
- EMPIRICAL (Go tests): evanphx/json-patch v4 (kustomize CLI + Flux kustomize lib) applies RAW `//` empty-key paths OK; `~1` escape FAILS in v4; evanphx v5 fails BOTH. kustomize SMP fails on empty-string key `values.services."":` (pre-existing bug in all 3 overlays)
- FIX VALIDATED: convert overlay SMP patches → JSON6902 with raw `//` paths (works in CLI kustomize AND Flux — both use kustomize's patchjson6902 filter with evanphx v4)
- E2E PRE-EXISTING BROKEN: scripts/test-template-e2e-local.sh requires deploy/base/knative-service.yaml (line 223) which no longer exists (helm-chart migration); it deploys via its own OCI flow bypassing template overlays. SSH switch does NOT change its state → e2e mitigation DROPPED from Task 2
- CI template-e2e-test.yaml also uses its own OCIRepository+Kustomization flow (lines 695-747) — template's overlay/HelmRelease GitOps path is untested everywhere; overlay fix makes it CLI-buildable for the first time
- cargo-generate 0.23.8: no --defaults flag; use --silent + complete values file + --define (bools must be true/false, not 0/1); --destination dir must pre-exist; --path inside git repo reads git INDEX (copy template to temp without .git first)

## 2026-09-08 Task 2 (SSH switch + prod ns + JSON6902 conversion)
- git-repository.yaml switched to ssh://git@github.com/{{ github_org }}/{{ github_repo }}.git + ACTIVE secretRef github-deploy-key (interval/ref unchanged)
- deploy/overlays/prod/namespace.yaml created (Namespace production, part-of label); listed FIRST in prod overlay resources
- All 3 overlays converted SMP → JSON6902: scalar leaf `op: replace` on raw `//` paths (e.g. /spec/values/services//scaling/minScale); conditional postgres/kafka blocks → `op: add` on /spec/values/postgres|kafka wrapped in same liquid conditionals; dev env list replaced wholesale via one `op: replace` on /spec/values/services//env
- VERIFIED on generated project (combo 0,0,0): kustomize build deploy/overlays/prod GREEN + contains kind: Namespace/name: production + minScale: 2/maxScale: 20; dev overlay renders minScale: 0/maxScale: 3 — patches APPLY values, not just build
- Harness single-combo after fix: only Tasks 3-6 artifacts still red (deploy.sh, create-github-env.sh, deploy.yaml, Makefile targets) — git-repository/namespace/overlay-build assertions all green
- HTTPS GitRepository URL references found elsewhere: deploy/infrastructure/gha-runner/helmrelease.yaml:25 (githubConfigUrl — ARC config, NOT GitRepository auth; correct as HTTPS, left alone); docs/POSTGRES_FLUXCD.md:36 + docs/DEPLOYMENT.md:247 (docs — Task 7 owns)
- E2E note: scripts/test-template-e2e-local.sh remains PRE-EXISTING BROKEN (needs deploy/base/knative-service.yaml, gone post-helm-chart-migration); SSH switch does not change its state; not fixed per scope amendment

## 2026-09-08 Task 4 (gha-runner RBAC + serviceAccountName)
- rbac.yaml.liquid: SA `<name>-runner` (actions-runner-system) + flux-system Role/RoleBinding (gitrepos rwx/glcw, helmcharts glcw, helmreleases/kustomizations rwx, secrets glc-up, conditional image CRs) + production Role/RoleBinding (ksvc/services ro, pods c/d/g/l, pods/log get, events get); both subjects use `namespace: actions-runner-system`
- kustomization.yaml: rbac.yaml listed FIRST (SA exists before scale-set HelmRelease references it)
- helmrelease.yaml: `serviceAccountName: <name>-runner` under values.template.spec next to priorityClassName — renders correctly in generated project (`prod-matrix-app-runner`)
- TRAP: acceptance grep `ClusterRole` count must be 0 — the word appears in COMMENTS too (header said "no ClusterRole/ClusterRoleBinding" → reworded to "no cluster-scoped roles or bindings")
- Harness awk RoleBinding-subject check matches ANY `namespace: actions-runner-system` line inside the `---`-delimited RoleBinding doc — metadata namespace (flux-system/production) does not collide
- Harness 1,0,0: ALL RBAC assertions green (kustomize build ✓, SA=1, RoleBinding=2, subject ns ✓, imageupdateautomations absent, no liquid residue); remaining 8 failures are Tasks 3/5/6 artifacts
- Toggle verified: 1,1,0 renders image.toolkit.fluxcd.io rule (imagerepositories/imagepolicies/imageupdateautomations); 1,0,0 renders none

## 2026-09-08 Task 5 (prod-github-env script + target)
- scripts/prod/create-github-env.sh: Gen-1 style (#!/bin/bash, set -euo pipefail, SCRIPT_DIR/PROJECT_ROOT, →/✓/⚠/✗ log helpers mirroring setup-github-runners.sh)
- Interface: env vars GITHUB_ORG/GITHUB_REPO (Makefile passes them; empty today until Task 3 defines the vars — undefined make vars expand to '' which the script treats as unset → gh repo view fallback keeps standalone use working)
- Idempotency contract: GET environment first (rc 0 → skip; stderr contains "404" → create; else hard fail); POST tolerates 409/422 as idempotent success (race safety); branch policies GET list → jq .branch_policies[].name → exact newline-delimited match (NOT substring — avoids "main" matching "domain") before POST
- set -e-safe gh probing idiom: `out="$(gh api ... 2>&1)" && rc=0 || rc=$?` — separate `local` declaration from assignment (one-line `local x=$(cmd)` masks the exit code)
- NON-FATAL v* rule: add_branch_policy returns 0 on ANY failure of the v* POST (warning + manual path: Settings → Environments → production → Deployment branches and tags → Add deployment tag or branch rule); overall exit stays 0 per MUST DO
- --dry-run: resolves org/repo from env vars ONLY (deliberately skips `gh repo view` — that call hits the network, violating "zero network calls"); unset vars render as <org>/<repo> placeholders + hint; auth check intentionally NOT run in dry-run (works without gh installed)
- gh 404 detection is string-match on captured 2>&1 output ("HTTP 404") — gh api exits 1 uniformly for all HTTP errors, no status-code flag on the error path
- Makefile: add-only diff appended after bootstrap section (new "Production Setup Commands" block); help awk pattern `^[a-zA-Z_-]+:.*?## ` matches prod-github-env automatically
- Evidence: task-5-dryrun.txt (bare → placeholders; GITHUB_ORG/GITHUB_REPO → resolved; both exit 0, all 4 planned calls incl. environments/production + deployment-branch-policies + main + v*), task-5-noauth.txt (stub gh in /tmp/opencode/stub-bin-noauth exiting 1 on auth status → exit 1 with "gh auth login" guidance before any API call)
- bash -n ✓, make -n prod-github-env ✓, read -p count 0 ✓, common.sh count 0 ✓; harness needles satisfied: prod-github-env: + GITHUB_ORG now present in Makefile

## 2026-09-08 Task 2 fix (postgres/kafka JSON6902 add-regression)
- EMPIRICAL FACT (evanphx/json-patch v4): `op: add` on an EXISTING path REPLACES the whole subtree — add {"instances":5} on /postgres wipes base's enabled/pooler/etc. Original SMP deep-merged; JSON6902 does not
- FIX PATTERN: conditional postgres/kafka overlay blocks must be individual `op: replace` ops on EXISTING leaf paths (e.g. /spec/values/postgres/instances, /spec/values/postgres/backup/objectStore/destinationPath, /spec/values/kafka/sources/<topic>/consumers) — every such leaf exists in base helmrelease when the flag is on
- Applied to all 3 overlays; prod kafka also patches delivery/retry + delivery/backoffDelay (both exist in base delivery); dev postgres also patches pooler/instances + pooler/parameters/{max_client_conn,default_pool_size} (exist in base pooler)
- SEMANTIC PROOF (pgkafka-app generated with feature_postgres=true + event_source_kafka=true, all 3 overlays kustomize build OK, zero liquid residue): base-only fields preserved (postgres.enabled: true, version "16", sharedPreloadLibraries, postInitSQL, pooler, monitoring, backup s3Credentials, kafka topic/consumerGroup/sink/dlq/backoffPolicy) AND overlay overrides applied (prod: instances 3, synchronous_commit remote_apply, destinationPath .../prod/, initialOffset latest, consumers 10, retentionPolicy 30d, maxParallel 8; staging: 2/on/staging/earliest/5/14d/4; dev: 1/local/dev/earliest/1/7d/2)
- Note: rsync not on this box — harness-style template copy done with cp -a + rm .git/target/.opencode/.sisyphus
- Harness combo 0,0,0 re-run after fix: overlay + git-repository + namespace assertions still GREEN (remaining failures = Tasks 3-6 artifacts only)

## 2026-09-08 Task 6 (deploy.yaml.liquid workflow)
- CRITICAL cargo-generate trap: liquid PARSE errors → hard generation failure ("Substitution skipped, found invalid syntax"); liquid RENDER errors → SILENT verbatim file copy (render_string_gracefully fallback in src/template.rs). Symptom of the silent path: rendered file contains {% raw %}/{% if %} tags INTACT, generation exits 0, no warning
- ROOT CAUSE hit: unwrapped `${{ github.workspace }}` inside a run block — liquid parses `{{ github.workspace }}` as a variable lookup, render fails (not a "requested variable" retry case) → whole file copied unprocessed. FIX: use `$GITHUB_WORKSPACE` bash env var instead (no liquid needed); wrapping in {% raw %} also works (both verified)
- Liquid has NO `not` operator — `{% if not flag %}` is a PARSE error (aborts generation). Repo convention is `{% unless flag %}...{% endunless %}` (Cargo.toml.liquid:77). Plan's `{% if not feature_gha_runner %}` spec had to be translated
- Harness greps `@latest` ANYWHERE in rendered workflow — even inside a comment ("NO @latest") trips it; keep the word out of comments entirely
- Workflow shape that satisfies all harness assertions: top-level permissions: contents: read; concurrency group "prod-deploy-{% raw %}${{ github.ref }}{% endraw %}" + cancel-in-progress: false; job-level environment: production + timeout-minutes: 45; runs-on conditional copied verbatim from ci.yaml.liquid:20; pinned KUBECTL_VERSION v1.31.4 (dl.k8s.io/release/$VER/bin/linux/amd64/kubectl) + FLUX_VERSION v2.4.0 (github.com/fluxcd/flux2/releases/download/$VER/flux_${VER#v}_linux_amd64.tar.gz) as env vars
- Kubeconfig step (non-ARC only): secret passed via step `env:` (never interpolated into run script — multi-line safe), umask 077 + printf '%s' > file (0600), exported via GITHUB_ENV so `make prod-deploy` + diagnostics inherit KUBECONFIG; empty-secret fail-fast message: "set the PROD_KUBECONFIG secret in the production environment"
- Diagnostics step: `if: failure()` + `kubectl get kustomization,gitrepository,helmrelease -A --no-headers || true` — guarded so it can never fail the job
- Verified both toggles: 0,0,0 → all workflow assertions green + secrets.PROD_KUBECONFIG present; 1,0,0 → green + secrets.PROD_KUBECONFIG count 0 + runs-on prod-matrix-app-runner + zero {% residue + yaml.safe_load OK
- Remaining harness failures in both combos are Task 3 artifacts only (scripts/prod/deploy.sh missing; Makefile prod-deploy:/prod-kubeconfig:/PROD_KUBECONFIG_PATH) — expected while Task 3 runs in parallel
- Evidence: task-6-workflow.txt (0,0,0), task-6-workflow-toggle.txt (1,0,0 + rendered-file toggle checks)

## 2026-09-08 Task 3 (prod-deploy target + deploy.sh)
- Makefile add-only: PROD_KUBECONFIG_PATH/GITHUB_ORG/GITHUB_REPO/GITHUB_REPO_SSH vars after CRATE_NAME (liquid, completes prod-github-env wiring which referenced $(GITHUB_ORG)/$(GITHUB_REPO)); prod-deploy target passes the 3 GitHub vars as env prefixes on the script call; prod-kubeconfig mirrors dev-kubeconfig echo
- EMPIRICAL: `kubectl apply -k deploy/flux/config/prod` FAILS under default LoadRestrictionsRootOnly ("file is not in or below" on ../../kustomization-prod.yaml; kubectl 1.36, kustomize 5.8.1); `kubectl apply` does NOT expose --load-restrictor. WORKING form: `kubectl kustomize --load-restrictor LoadRestrictionsNone <dir> | kubectl apply --server-side -f -` (renders ONLY Flux config objects — Kustomizations/image CRs — Flux applies all workloads; within runner RBAC)
- LATENT BUG (existing, NOT fixed — out of scope): Makefile bootstrap line ~280 `kubectl apply --server-side -k "$CONFIG"` would hit the same load-restriction failure today
- CRITICAL cargo-generate gotcha: deploy.sh contained literal `*'{{'*` glob → cargo-generate "Substitution skipped, found invalid syntax in scripts/prod/deploy.sh" → generation FAILED. Fix: build the brace-pair marker at runtime (`liq_start="$(printf '%s%s' '{' '{')"`) — new scripts under a liquid template must contain NO adjacent `{{` or `{%` byte sequences anywhere
- RBAC-driven design decisions (runner SA per rbac.yaml.liquid): cluster-scope pre-flights (get ns, get deployment) treat Forbidden/403 as warn+continue (NotFound still fails fast); cluster-info falls back to `kubectl get --raw=/readyz` (in system:discovery ClusterRole, granted to all authenticated users); helmrelease wait in production can 403 (helmrelaces granted in flux-system ONLY but HelmRelease lives in production) → Forbidden = skip to ksvc wait (the authoritative RBAC-granted gate), non-Forbidden = fail with conditions+yaml dump; events get (NOT list) → `kubectl get events` in diagnostics wrapped in || true (degrades for runner)
- Detached-pod smoke pattern (new code, adapted from template-e2e-test.yaml:798-843): pod_curl sets globals SMOKE_EXIT_CODE/SMOKE_OUTPUT/SMOKE_POD_PHASE and ALWAYS returns 0 (set -e safe); curl `-w '\n%{http_code}'` appends status as last log line → smoke_parse splits body/code; 124 sentinel = pod stuck non-terminal, 125 = create failed; fallback retry on curl 6/7/28/124 against http://<name>.production.svc.cluster.local; trap EXIT deletes all SMOKE_PODS --ignore-not-found --wait=false
- set -e traps avoided: FAILED=$((FAILED+1)) never ((FAILED++)) (post-increment of 0 returns exit 1 = fatal as final || command); `out="$(cmd)" && rc=0 || rc=$?` idiom for probes
- Stub-kubectl QA technique: case-dispatch on $* patterns (jsonpath content first — args arrive quote-stripped, e.g. `jsonpath={.status.phase}`), stateful run→logs correlation via pod-name state file, pipe-consumer MUST `cat >/dev/null` before exit 0 (else SIGPIPE breaks pipefail); 5 stub scenarios: dry-run/no-cluster, missing-kubeconfig, flagger fail-fast, full happy path, deploy-key auth path (stateful wait-fail→create→poll), smoke 503 failure (exit 1, FAILED counter)
- Evidence: task-3-dryrun.txt (exit 0, 9 steps + 4 checks, all QA needles, 0 unprefixed mutating cmds), task-3-nokubeconfig.txt (exit 1, .kubeconfig-prod/prod-kubeconfig guidance), task-3-flagger.txt (exit 1 at pre-flight, "Install the Flagger operator CLUSTER-WIDE first", never reached apply), task-3-smoke-happy.txt (4/4 passed exit 0), task-3-deploykey-auth.txt (auth detect → secret guard → flux create → pubkey → poll success), task-3-smoke-failure.txt (readiness 503 → ✗ + diagnostics → exit 1)
- Harness: PROD_DEPLOY_MATRIX=0,0,0 → 1/1 PASSED; full matrix 8/8 PASSED (Task 6 workflow landed in parallel so nothing red remains)

## 2026-09-08 Task 7 (docs)
- docs/DEPLOYMENT.md: new "## Production Deployment" section inserted between "Environment-Specific Deployment" and "Rollback Procedures" (line 520) + TOC entry at line 45; existing sections untouched (add-only diff)
- Section covers: prerequisites (cluster-wide Flux/Knative/Flagger, kubectl/flux/gh, kubeconfig), one-time setup (prod-github-env idempotency + deploy-key first-run-fails-by-design flow with exact GitHub path + "Allow write access" only for enable_image_updates + never-rotate), usage (make prod-deploy, ./scripts/prod/deploy.sh --dry-run, GHA v* tag + workflow_dispatch), tag-does-NOT-pin-ref semantics blockquote, kubeconfig options table (KUBECONFIG env / .kubeconfig-prod / in-cluster SA), runner RBAC scope note (2 namespaces + secret read rationale), rollback (git revert + Flux, one paragraph), smoke suite table (4 checks with exact expected bodies)
- Cross-referenced DEPLOYMENT.md:105 `flux bootstrap github` as the complementary initial-install path so docs stay coherent (bootstrap installs Flux; prod-deploy deploys the service through running Flux)
- README.md.liquid: pointer added in BOTH template branches' "Kubernetes Deployment" sections (feature branch line 99 after bootstrap block; else branch line 749) linking to docs/DEPLOYMENT.md#production-deployment
- Accuracy sourced from shipped artifacts: deploy.sh header (9 steps, --dry-run, never-rotate), rbac.yaml.liquid header (2-namespace scope), deploy.yaml.liquid (v*/dispatch, PROD_KUBECONFIG only on non-ARC path, pinned v1.31.4/v2.4.0), create-github-env.sh (main + v* policies)
- Acceptance greps all green (evidence .sisyphus/evidence/task-7-docs.txt): '## Production Deployment' @520; prod-deploy=9 (>=3); prod-github-env=2 (>=1); 'deploy key' ci=3 (>=1); TODO/PLACEHOLDER/FIXME=0; prod-deploy in README.md.liquid=2 (>=1); TOC + dry-run + semantics-note + bootstrap-xref greps included in evidence
- Prose rule followed: no em/en dashes in new text (existing doc's arrow style → reused only in the GitHub settings path "Repo → Settings → Deploy keys")

## 2026-09-08 Task 8 (final validation sweep)
- FULL MATRIX 8/8 PASSED exit 0 (evidence task-8-matrix.txt); harness output is compact by design — only kustomize builds echo ✓, the other ~30 grep/awk/python assertions print ONLY on failure (fail() in scripts/test-prod-deploy-static.sh:93), so few lines + PASSED banner = all assertions green
- bash -n PASS on all 4 scripts (3 new + pre-existing e2e script); make -n prod-deploy/prod-github-env/prod-kubeconfig all rc=0; make help lists all 3 targets with ## doc descriptions
- e2e script UNTOUCHED: `git log 6dea175..HEAD -- scripts/test-template-e2e-local.sh` → zero commits (pre-existing breakage confirmed unchanged)
- Makefile diff 6dea175..HEAD is ADD-ONLY (0 deleted lines) and contains ZERO lines matching 'bootstrap' → bootstrap target recipe untouched
- Commit series (6dea175..HEAD) matches plan Commit Strategy EXACTLY (line 1048-1054): harness → SSH → RBAC → prod-deploy → prod-github-env → ci → docs. NOTE: task-8 work-order text listed github-env BEFORE prod-deploy, which contradicts the plan; actual git follows the plan (plan authoritative)
- ONE file outside the plan's per-task file lists: cargo-generate.toml (+1) in commit 1089fcd — adds scripts/test-prod-deploy-static.sh to template ignore[] so the harness doesn't ship into generated projects. Functionally required companion to Task 1; flagged in report as accounted-for deviation, not scope creep
- Liquid residue spot-verify (KEEP_OUTPUT=1 combo 1,1,1): kustomize build --load-restrictor LoadRestrictionsNone on deploy/flux/config/prod + deploy/overlays/prod + deploy/infrastructure/gha-runner → all rc=0, grep -F '{%' = 0 matches each; namespace production + kind: Namespace render correctly
- Evidence: task-8-matrix.txt (442 lines), task-8-diffstat.txt (18), task-8-commits.txt (7)

## 2026-09-08 F1 (plan compliance audit)
- VERDICT: APPROVE — Must Have [6/6] | Must NOT Have [10/10] | Tasks [8/8] | Deliverables [10/10]
- Independently re-ran every gate (did not trust evidence files): full-matrix harness 8/8 exit 0; bash -n clean on all 3 scripts; make -n prod-deploy/prod-github-env/prod-kubeconfig rc=0; deploy.sh --dry-run exit 0 (9 steps + 4 checks, all [dry-run]-prefixed); docs greps (prod-deploy=9, prod-github-env=2, deploy key ci=3, TODO=0); Makefile diff 6dea175..HEAD add-only, zero dev- lines touched; scripts/dev/ + e2e script zero commits
- Secret-rotation guard verified by code-path read: deploy.sh:418 kubectl get secret check PRECEDES :424 flux create secret git (create only in else branch; existing → print identity.pub + "NOT recreating")
- Flagger pre-flight verified: check_flagger_dependency only prints guidance + exit 1 (deploy.sh:353-358); no install path exists; Forbidden→warn+continue adaptation for RBAC-restricted identities is documented and NotFound still fail-fasts
- Apply-form deviation accepted (not a guardrail breach): 'kubectl kustomize --load-restrictor LoadRestrictionsNone | kubectl apply --server-side -f -' instead of plan's literal 'apply -k' — LoadRestrictionsRootOnly breaks on ../../kustomization-prod.yaml; in-code comment deploy.sh:653-657; intent (Flux-config-only applies) preserved
- Audit saved: .sisyphus/evidence/final-qa/F1-compliance-audit.txt (140 lines)

## F2 — Code Quality Review (final verification wave)
- Verdict: APPROVE. Syntax PASS (bash -n ×3 exit 0); shellcheck unavailable → manual lint equivalent (quoting/word-split/set -u/error-handling) clean; 17/17 changed files reviewed in full; 0 blockers, 0 majors, 3 minors, 4 nits. Evidence: .sisyphus/evidence/final-qa/F2-code-quality.txt
- Pattern worth keeping: every kubectl/gh/flux call in the 3 new scripts is guarded via one of: `if ! cmd`, `cmd || true`, or `out=$(cmd) && rc=0 || rc=$?`. The `&& rc=0 || rc=$?` capture keeps stdout+stderr in one string for Forbidden substring matching — a clean set -e-safe idiom for degrade-gracefully pre-flights.
- RBAC gap found (minor, not fixed — review only): rbac.yaml.liquid grants events:[get] but deploy.sh's failure diagnostic `kubectl get events` is a LIST → silently empty under the runner SA. If anyone touches RBAC next, add `list` (and consider `watch` for kubectl wait if ever used on pods).
- create-github-env.sh nuance: the TAG_PATTERN non-fatal branch swallows 409/422 duplicate races as "GitHub rejected" — outcome is still idempotent success, so it's cosmetic. Order the 409/422 check BEFORE the pattern-specific branch if refactoring.
- cargo-generate conditional ignore (`[conditional.'!feature_gha_runner'] ignore=[dir]`) is what makes the harness's "dir must be ABSENT when flag=0" assertion satisfiable — cargo-generate CAN exclude whole dirs per-flag, not just template content.
- Overlay trio (prod/staging/dev) structurally identical patch skeletons; only values + a few env-specific ops differ (prod-only kafka delivery tuning, dev-only pooler/image/env). No copy-paste drift — treat these three as one unit when editing.
- deploy.sh:780 no-op `if [[ ! -t 0 ]]; then :; fi` judged acceptable (documented CI-safe contract marker), not slop.

## 2026-09-08 F3 (Real QA Execution — final verification wave)
- ALL 16 executable QA scenarios re-executed fresh + 1 N/A (red-state: precondition "feature tasks not yet implemented" no longer holds — documented in F3-task1-red-NA.txt referencing prior task-1-red.txt evidence). 16/16 PASS.
- Full matrix re-run CONFIRMED: 8/8 combos PASSED exit 0 (F3-task8-matrix.txt) — independent re-execution matches Task 8 result.
- Harness single-combo 0,0,0: exactly 1 generation banner ✓; full matrix: 8 banners ✓ (banner = 'Combo N:' line).
- Overlay values proof re-verified on fresh KEEP_OUTPUT=1 combo 0,0,0 project: prod minScale 2/maxScale 20, dev minScale 0/maxScale 3, kind: Namespace count 1, raw '//' paths 6 — JSON6902 patches APPLY (not just build).
- RBAC counts re-verified on fresh 1,0,0 render: SA=1, Role=2, RoleBinding=2, ClusterRole=0, image CRs absent; 1,1,0 render: imageupdateautomations + imagerepositories + imagepolicies all present; serviceAccountName=1, SA name prod-matrix-app-runner.
- Workflow toggle re-verified: 0,0,0 → secrets.PROD_KUBECONFIG=1 + fail-fast message + runs-on ubuntu-latest; 1,0,0 → PROD_KUBECONFIG=0 + runs-on prod-matrix-app-runner; both yaml.safe_load OK, 0 liquid residue, pins KUBECTL v1.31.4 / FLUX v2.4.0.
- Plan T4 combo 0,1,0 nuance: with gha_runner=0 the RBAC Role cannot exist (dir correctly absent) — image-CR toggle provable only on gha_runner=1 combos (1,0,0 vs 1,1,0); 0,1,0 still passes harness (proves flag gating). Noted in F3-task4-rbac-toggle.txt.
- Stub QA re-ran clean: kubectl stub (5 subcommand cases incl. NotFound for kustomization/flagger — must NOT contain 'Forbidden'/'403' or script treats it as RBAC-warn+continue) → exit 1 at pre-flight, 'Install the Flagger operator CLUSTER-WIDE first', 0 stub-unexpected calls, never reached apply. gh stub (auth status→1) → exit 1 'gh auth login' before any API call.
- deploy.sh --dry-run needles all present (git-repository/github-deploy-key/config/prod/ksvc/4 health paths, [1/9]..[9/9]), 0 unprefixed mutating cmd lines; dry-run exits 0 with NO kubeconfig at all (step 1 prints planned resolution, no cluster contact).
- T5 dry-run evidence grep note: '^\s*gh api' count 5 = the PRINTED planned-call preview lines (expected dry-run output), not executed calls — script makes zero network calls (stub would have caught any).
- F3 evidence: .sisyphus/evidence/final-qa/F3-task{1..8}-*.txt (17 files incl. red-state N/A note). Repo untouched: git status clean except untracked .sisyphus/. Stubs: /tmp/opencode/f3-stub-bin/{kubectl}, /tmp/opencode/f3-stub-bin-noauth/{gh} (+ fake kubeconfig at /tmp/opencode/f3-fake-kubeconfig/config). KEEP_OUTPUT dirs left in /tmp (tmp.PjEsF6kcZK, tmp.ZBrDvW9Trh, tmp.zXDtVZOuMm, tmp.AqjUzEhpYg) for cross-reviewer inspection.

## 2026-09-08 F4 (scope fidelity check — audit only)
- 7/7 commits map 1:1 to plan tasks; chronological order = tasks 1,2,4,5,3,6,7 vs Commit Strategy literal list 1,2,4,3,5,6,7 → commits 4↔5 swapped (per Wave structure + F4 briefing; benign — Task 5's target referenced $(GITHUB_ORG)/$(GITHUB_REPO) before Task 3 defined them, undefined make vars expand empty, script has fallback)
- Per-task fidelity: 8/8 compliant. TWO spec-letter gaps found: (D1) T1 harness has NO runs-on conditional assertion for deploy.yaml (spec listed it; workflow itself correct, toggle verified in task-6 evidence) — suggested follow-up: add grep assertion; (D2) T6 "Upload smoke-suite diagnostics" implemented as log-based kubectl dump, NO actions/upload-artifact — intent (failure diagnostics) met, artifact transport absent
- Documented micro-deviations (all empirically forced / orchestrator-approved): T3 flagger Forbidden→warn+continue (NotFound still fail-fast); T3 'kubectl apply -k' → kustomize|apply pipe; T6 {% unless %} for {% if not %} + $GITHUB_WORKSPACE; T2 conditional blocks leaf op: replace (plan L318 "add ops" wording stale)
- Must-NOT-do: ZERO violations across all 8 tasks + global guardrails (verified by grep per commit: read -p 0, common.sh 0, --rm -i 0, clusterrole 0, secrets-in-production-role 0, @latest 0, required reviewers 0, docker 0, Makefile deleted-lines 0, e2e/scripts-dev/base 0 commits)
- Contamination CLEAN: per-commit file sets = plan file lists exactly; Makefile shared by T3+T5 with disjoint add-only hunks
- Unaccounted CLEAN: 17 files, 16 exact + cargo-generate.toml = documented attributable exception, verified diff is ONLY the 1-line ignore entry
- Amendment verification: plan L318/L319 reflect BOTH amendment parts (JSON6902 conversion + e2e mitigation dropped); diffs match amended scope. Plan-internal staleness: L318 "add ops" sentence predates leaf-replace refinement; Commit Strategy L1049 still lists "+ e2e mitigation" (commit 2 has none)
- T7 docs verified add-only (90 added/0 deleted); README pointer in BOTH template branches; rollback section covers git-revert story (phrased "revert the offending commit" — literal string "git revert" absent but semantics covered)
- T8's "commit order matches plan EXACTLY" claim glossed the 4↔5 swap (data correct, interpretation loose) — cosmetic
- VERDICT: APPROVE — Tasks [8/8] | Contamination [CLEAN] | Unaccounted [CLEAN/1 attributable] | Evidence: .sisyphus/evidence/final-qa/F4-scope-fidelity.txt
