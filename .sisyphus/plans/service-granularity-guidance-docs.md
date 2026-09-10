# Service Granularity Guidance Docs — Decision Framework Documentation

## TL;DR

> **Quick Summary**: User consulted on Knative service granularity (multi-binary workspace vs single binary with all routes) and chose **guidance only**: document the verified decision framework in the template's docs — no code restructure, no scaffolder build. Oracle-verified Knative facts (per-Revision scaling, Eventing ref+uri routing, minScale economics) become a user-facing decision doc, with template-author mechanics noted in TEMPLATE_GUIDE.
>
> **Deliverables**:
> - `docs/SERVICE_GRANULARITY.md` — user-facing decision framework (ships with generated projects, ≤300 lines)
> - Cross-links: unconditional pointer in `README.md.liquid` + author-facing notes/anchor in `docs/TEMPLATE_GUIDE.md`
> - Single atomic commit after all QA green
>
> **Estimated Effort**: Quick (single session)
> **Parallel Execution**: YES — 2 waves
> **Critical Path**: T1 (write doc) → T2 (cross-links) ∥ T3 (generation smoke) → user okay → T4 (atomic commit)

---

## Context

### Original Request
User asked: "Is there a way for cargo generate to generate snippets of code so that we can have it quickly set up a new binary with new Axum routes that would reference a common shared crate but compile and deploy code separately so that we can keep our Knative services small — or does it just make sense to have the Knative service effectively have all routes but let Knative Serving and Eventing manage which endpoint it's routed to?"

### Interview Summary
**Key Discussions**:
- Consulted Oracle on the architecture trade-off; user then chose **"Guidance only for now"** — document split criteria and shared-crate patterns in template docs; NO code restructure yet.
- IF a scaffolder is built later: user prefers **cargo-generate sub-template** mechanism (recorded in TEMPLATE_GUIDE notes).
- Flagger Canary emission for future scaffolder-added services: user chose **"Defer this decision"** — doc mentions it as a known consideration only (in author-facing TEMPLATE_GUIDE, not re-opening the decision).

**Research Findings** (Oracle-verified against repo + Knative spec):
- Template is currently single-binary: `Cargo.toml.liquid` is `[package]`, one binary, routes centralized in `src/routes.rs`, Dockerfile builds one binary via cargo-chef.
- `deploy/base/helmrelease.yaml` values contain a `services:` **map** — the chart already renders one Knative Service per map key with per-service scaling/resources/probes. Deploy side is multi-service capable today.
- Knative autoscaling (minScale/maxScale/concurrency/timeout) is **per-Revision only**; changing podspec-template annotations creates a new revision (knative/serving#6717) → each new revision triggers Flagger analysis. No per-route scaling exists.
- Knative Eventing routing: `duckv1.Destination` with `ref` + relative `uri` resolves to `<ref-url><path>` (spec-verified) — different event types CAN target different paths of the same service. Eventing routing is NOT a reason to split.
- minScale economics: default 0 under KPA + scale-to-zero → splitting costs ~nothing idle (queue-proxy overhead per pod); minScale≥1 on N services = N always-on pods.
- Per-binary dep isolation is impossible inside one Cargo package (all `[[bin]]` targets share one feature set/dep graph) — relevant to future workspace restructure, documented as a criterion not implemented.
- `docs/TEMPLATE_GUIDE.md` is in the cargo-generate global ignore list (`cargo-generate.toml:11`) — it is template-author-only and does NOT ship to generated projects.
- e2e tests do not assert exact `docs/` trees — adding a docs file breaks nothing.
- **LIQUID TRAP**: cargo-generate renders Liquid in ALL non-ignored files, including plain `.md`. Any `{{ }}` or `{% %}` in the doc must be wrapped in `{% raw %}...{% endraw %}` or generation will mangle/abort.

### Metis Review
**Identified Gaps** (addressed):
- **Liquid brace corruption in plain .md** → hard guardrail: `{% raw %}` around any brace-containing YAML examples; generation smoke test (T3) is mandatory, not optional.
- **Audience split** → doc stays user-facing (generated-project audience); template mechanics (sub-template preference, kustomize-can't-loop Canary consideration, cargo-chef `--bin` scoping) go to TEMPLATE_GUIDE (author-only).
- **Conditional-wrapped README link risk** → link MUST be placed outside all `{% if %}` blocks; verified by reading placement, since `--defaults` smoke test would not catch a conditional-wrapped link.
- **No docs index in TEMPLATE_GUIDE** → create a small "Multi-service roadmap notes" anchor section there.
- **Drift risk** → one-line "verify against your Knative version" note in the doc; no full version-compat section (that would be creep).
- **Length budget** → ≤300 lines cap on the user-facing doc.

---

## Work Objectives

### Core Objective
Give template users a verified, versioned decision framework for choosing between single-binary-with-all-routes and per-service binaries on Knative — documented in the repo, shipping with generated projects, without changing any code or build behavior.

### Concrete Deliverables
- `docs/SERVICE_GRANULARITY.md` (new, user-facing, ≤300 lines)
- `README.md.liquid` (one unconditional link, existing link style)
- `docs/TEMPLATE_GUIDE.md` (new short anchor section: multi-service roadmap notes for template authors)

### Definition of Done
- [ ] `test -f docs/SERVICE_GRANULARITY.md` succeeds; `wc -l` ≤ 300
- [ ] All AC-1…AC-7 checks green (see task QA scenarios)
- [ ] Generation smoke test: `cargo generate --path . --defaults --allow-commands` output contains uncorrupted doc + rendered README link
- [ ] `git show --stat HEAD` shows exactly 3 files; `git status` clean
- [ ] `cargo check` still passes (no code touched — sanity only)

### Must Have
- Verified fact coverage in the doc (AC-3 keyword list): minScale economics, per-Revision autoscaling + revision-churn/Flagger interaction, Eventing ref+uri path routing, the 4 split criteria, the 2 anti-criteria, dep-weight/cold-start guidance
- `{% raw %}` protection on any brace-containing examples
- Unconditional README link following the existing pattern at `README.md.liquid:331`
- One-line "verify against your Knative version" note

### Must NOT Have (Guardrails)
- NO code changes whatsoever: no `.rs`, `Cargo.toml*`, `Dockerfile`, `Makefile.liquid`, or deploy manifest edits
- NO edits to `cargo-generate.toml` ignore lists (global OR conditional) — the new doc must ship unconditionally; also remember ignored files are deleted BEFORE post hooks run (`cargo-generate.toml:36-40` comment)
- NO scaffolder/sub-template implementation (deferred by user)
- NO backlink edits to `docs/ARCHITECTURE.md` / `docs/KNATIVE_CONSTRAINTS.md` (scope locked: README + TEMPLATE_GUIDE only)
- NO CHANGELOG.md entry
- NO new scripts/tests committed to the repo — QA runs as ad-hoc commands only
- NO reorganizing/rewriting existing docs beyond the two link insertions
- NO `{{` / `{%` sequences in the doc outside `{% raw %}` blocks
- No "user reviews doc quality" acceptance criteria — verification is command-based only

---

## Verification Strategy (MANDATORY)

> **ZERO HUMAN INTERVENTION** - ALL verification is agent-executed. No exceptions.

### Test Decision
- **Infrastructure exists**: YES (cargo test suite exists) but NOT applicable — documentation-only change
- **Automated tests**: None (docs only); verification via exact grep/file assertions + template generation smoke test
- **Framework**: none (no test code added)

### QA Policy
Every task MUST include agent-executed QA scenarios (see TODOs below).
Evidence saved to `.sisyphus/evidence/task-{N}-{scenario-slug}.{ext}`.
- **Docs**: Bash (grep/test/wc) assertions + one full `cargo generate` smoke test
- No Playwright/tmux needed for this plan

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Start immediately):
└── Task 1: Write docs/SERVICE_GRANULARITY.md [writing]

Wave 2 (After Task 1 — MAX PARALLEL):
├── Task 2: Cross-links (README.md.liquid + docs/TEMPLATE_GUIDE.md) [quick]
└── Task 3: Generation smoke test (AC-6) [quick]

Wave FINAL (After ALL tasks — 4 parallel reviews, then user okay):
├── Task F1: Plan compliance audit (oracle)
├── Task F2: Quality review of docs + repo sanity (unspecified-high)
├── Task F3: Full QA re-run of every scenario (unspecified-high)
└── Task F4: Scope fidelity check (deep)
-> Present results -> Get explicit user okay

Wave 3 (After user okay on F1-F4):
└── Task 4: Atomic commit [quick, git-master skill]

Critical Path: T1 → T2 → F1-F4 → user okay → T4
Parallel Speedup: T2 ∥ T3 saves one sequential step
Max Concurrent: 2 (Wave 2), 4 (Final Wave)
```

### Dependency Matrix

| Task | Depends On | Blocks |
|------|-----------|--------|
| 1 (write doc) | None | 2, 3 |
| 2 (cross-links) | 1 (filename + section anchors contract, pre-agreed) | F1-F4 |
| 3 (smoke test) | 1 | F1-F4 |
| F1-F4 | 2, 3 | 4 (plus explicit user okay) |
| 4 (commit) | F1-F4 ALL APPROVE + user okay | None |

> Note: T2 and T3 are parallel-safe because T2's link target filename (`docs/SERVICE_GRANULARITY.md`) and anchor names are fixed by this plan before T1 runs.

### Agent Dispatch Summary

- **Wave 1**: 1 — T1 → `writing`
- **Wave 2**: 2 — T2 → `quick`, T3 → `quick`
- **FINAL**: 4 — F1 → `oracle`, F2 → `unspecified-high`, F3 → `unspecified-high`, F4 → `deep`
- **Wave 3**: 1 — T4 → `quick` (skill: `git-master`)

---

## TODOs

> Implementation + QA = ONE Task. Never separate.
> EVERY task has: Recommended Agent Profile + Parallelization info + QA Scenarios.

- [ ] 1. Write `docs/SERVICE_GRANULARITY.md` — user-facing decision framework

  **What to do**:
  Create a NEW file `docs/SERVICE_GRANULARITY.md` (user-facing; ships with generated projects) with this exact outline and content, ≤300 lines total:

  1. **Title + purpose** (3-5 lines): how to decide between "one Knative Service carrying all routes" vs "multiple Knative Services (separate binaries)", written for someone who generated a project from this template.
  2. **TL;DR decision table**: factor → which option it favors (scaling divergence→split; uniform low traffic→single; independent release cadence→split; Eventing routing needs→single (ref+uri); minimal ops surface→single; heavy deps used by only some endpoints→split).
  3. **What Knative actually gives you** (verified facts — do not invent behavior):
     - Autoscaling (`minScale`, `maxScale`, `containerConcurrency`, timeout, resources) is **per-Revision, never per-route**. KPA scales each Service on aggregate concurrency. There is no per-path scaling, minScale, or timeout.
     - Changing podspec-template annotations (e.g. minScale) **creates a new Revision** (knative/serving#6717); each new revision triggers a Flagger analysis cycle when canaries are enabled — with one binary, infra tweaks burn rollout windows for every logical endpoint.
     - **minScale economics**: default minScale is 0 (KPA + scale-to-zero), so splitting costs ~nothing while idle (small per-pod queue-proxy overhead); minScale ≥ 1 on N services = N always-on pods vs 1. minScale is THE cost knob of splitting.
     - **Eventing routing**: a `duckv1.Destination` with `ref` (Knative Service) + relative `uri` (e.g. `uri: /events/orders`) delivers to `<service-url>/events/orders` — verified against the Eventing control-plane spec. Different event types can target different paths of the SAME service via Trigger subscribers / Source sinks. BUT all deliveries share one scaling pool, and any event type wakes the whole binary. Include one small YAML example — MUST be wrapped in `{% raw %}...{% endraw %}` (see Must NOT do).
  4. **Split criteria — split out a service when** (the 4, ranked): (1) divergent scaling profile — the only strict requirement (heavy/streaming/long-poll route skews the shared pool's concurrency target for light routes); (2) dependency weight / cold-start isolation (e.g. Kafka producer init ~100-200ms + image size paid by every endpoint in a combined binary); (3) independent release cadence / blast radius (one binary = one revision stream; rollback and canary are all-or-nothing); (4) divergent concurrency/timeout profile (a 30s-streaming endpoint and a 10ms CRUD endpoint shouldn't share a pool).
  5. **Anti-criteria — do NOT split for**: Eventing routing (ref+uri handles per-event-type path dispatch); code organization (Axum modules suffice). Also note the counterweight: a single binary's sparse routes inherit warmth from busy routes sharing the revision pool — split services cold-start independently.
  6. **Dependency-weight note for the future**: within one Cargo package, all binaries share one feature set/dependency graph (deps link per-binary regardless of `[[bin]]` count). Keeping individual services small requires a Cargo workspace with a lean shared crate whose heavy deps (rdkafka, opendal) sit behind **empty-default Cargo features** that each binary opts into. This template currently generates a single package; see `docs/TEMPLATE_GUIDE.md` (template-author doc) for the planned path. This section describes criteria only — no promises of implementation.
  7. **Ops-surface counterweight**: N services = N images, N CI jobs, N canaries vs 1.
  8. **Decision walkthrough**: two short worked examples (e.g. "uniform CRUD API at low traffic → stay single"; "24/7 minScale=1 inference endpoint + bursty admin API → split").
  9. **Version note** (one line): autoscaling/Eventing behaviors summarized here are Knative-version-sensitive — verify against the Knative version your cluster runs (see also `docs/KNATIVE_CONSTRAINTS.md`).
  10. **Related docs**: link `./ARCHITECTURE.md` and `./KNATIVE_CONSTRAINTS.md` (links only, no edits to those files).

  **Must NOT do**:
  - Do NOT put any `{{` or `{%` sequence outside `{% raw %}...{% endraw %}` blocks — cargo-generate renders Liquid in plain `.md` files and will mangle or abort generation. Wrap the entire YAML example (and anything brace-y) in raw blocks.
  - Do NOT edit `cargo-generate.toml`, any `.rs` file, `Cargo.toml.liquid`, `Dockerfile`, deploy manifests, `docs/ARCHITECTURE.md`, `docs/KNATIVE_CONSTRAINTS.md`, or `CHANGELOG.md`.
  - Do NOT describe the scaffolder as implemented or promise implementation dates.
  - Do NOT exceed 300 lines.

  **Recommended Agent Profile**:
  - **Category**: `writing` — pure prose deliverable; content facts are pre-verified by this plan (no research needed; a research agent would re-open settled decisions)
  - **Skills**: `[]` — no domain skill overlaps (no browser, no k8s debugging; all facts are in this plan)
  - **Skills Evaluated but Omitted**: `deployment-planning`/`k8s-microservices-debug` (no deployment or debugging work — doc content already fixed), `document` (this is a single new doc with a fixed outline, not whole-repo documentation generation)

  **Parallelization**:
  - **Can Run In Parallel**: NO (starting point)
  - **Parallel Group**: Wave 1 (alone)
  - **Blocks**: Tasks 2, 3
  - **Blocked By**: None (can start immediately)

  **References** (CRITICAL - executor has NO context from the interview):

  **Pattern References** (existing code to follow):
  - `docs/KNATIVE_CONSTRAINTS.md` — existing doc covering Knative constraints; match its tone/format/heading style, and avoid duplicating its content (link instead). Confirm what it already says about ports/health/graceful shutdown so section 9's cross-reference is accurate.
  - `docs/ARCHITECTURE.md` — existing architecture doc; check its coverage of the single-binary layout so section 6/7 don't contradict it.
  - `README.md.liquid:331` and `:345` — the repo's doc cross-link style: `See [docs/X.md](./docs/X.md) for detailed ... guide covering:` (for T2, but read now to keep doc title conventions consistent).

  **API/Type References** (contracts to keep accurate):
  - `deploy/base/helmrelease.yaml:22-33` — the `services:` map with comment explaining empty-key behavior; section 6 may state the deploy layer already supports multiple services (keep wording consistent with this file).
  - `src/routes.rs:67-101` — current single-router layout (the thing a split would divide); section 5's "modules suffice" claim should match how routes are actually organized here.
  - `Cargo.toml.liquid:14-90` — current single-package dependency set (rdkafka/opendal behind template flags, not Cargo features); grounds section 6's feature-gating guidance.

  **External References**:
  - Knative Eventing spec on `duckv1.Destination` ref+uri resolution (fact already verified; cite as "Knative Eventing spec" without URL fabrication — or verify a URL via web search before including one)
  - knative/serving#6717 — annotation changes create revisions (same rule: cite name, verify any URL)

  **WHY Each Reference Matters**: the executor must not invent Knative behavior or contradict existing docs; every fact in the doc traces to this plan or these files.

  **Acceptance Criteria** (AGENT-EXECUTABLE VERIFICATION ONLY):

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: File exists, within budget, fact-complete
    Tool: Bash
    Preconditions: repo root is working directory
    Steps:
      1. test -f docs/SERVICE_GRANULARITY.md
      2. wc -l docs/SERVICE_GRANULARITY.md  → assert ≤ 300
      3. AC-3 keyword completeness — grep -il each of: "minScale", "revision", "duckv1.Destination",
         "concurrency", "cold", "rdkafka\|kafka producer", "cadence\|blast radius", "modules",
         "queue-proxy", "Knative version"
      4. grep -c "Split criteria" docs/SERVICE_GRANULARITY.md  → assert ≥ 1
      5. grep -c "do NOT split" docs/SERVICE_GRANULARITY.md  → assert ≥ 1 (anti-criteria section)
    Expected Result: file exists; ≤300 lines; every keyword found; both framework sections present
    Failure Indicators: any grep exits empty; line count > 300
    Evidence: .sisyphus/evidence/task-1-content-checks.txt

  Scenario: Ignore-list safety (AC-1 — run FIRST, expect failure before file exists)
    Tool: Bash
    Steps:
      1. grep -rn "SERVICE_GRANULARITY" cargo-generate.toml
    Expected Result: exit code 1 / zero matches (doc NOT in any global or conditional ignore list)
    Failure Indicators: any match — STOP and remove it; the doc must ship unconditionally
    Evidence: .sisyphus/evidence/task-1-ignore-list-check.txt

  Scenario: Liquid safety (AC-4)
    Tool: Bash
    Steps:
      1. grep -n '{{\|{%' docs/SERVICE_GRANULARITY.md
      2. For every match, read surrounding lines and assert it is inside a {% raw %}...{% endraw %} block
    Expected Result: zero brace sequences outside raw blocks
    Failure Indicators: any {{ or {% outside {% raw %} — generation WILL mangle/abort
    Evidence: .sisyphus/evidence/task-1-liquid-safety.txt
  ```

  **Evidence to Capture**: the 3 evidence files above (terminal output pasted/saved per scenario)

  **Commit**: NO (groups with Task 4 — single atomic commit at the end)

- [ ] 2. Cross-link from `README.md.liquid` + `docs/TEMPLATE_GUIDE.md`

  **What to do**:
  - In `README.md.liquid`: add ONE unconditional line following the existing style at `README.md.liquid:331`: `See [docs/SERVICE_GRANULARITY.md](./docs/SERVICE_GRANULARITY.md) for a decision framework on single-service vs multi-service Knative layouts.` — placed OUTSIDE every `{% if %}` block (read the file structure; do not nest it inside any feature conditional).
  - In `docs/TEMPLATE_GUIDE.md` (template-author-only doc, generation-ignored): add a short new anchor section titled **"Multi-service roadmap notes"** (~15-25 lines max) containing:
    - Future direction: Cargo workspace + lean `service-core` shared crate + thin per-service binaries (criteria live in `docs/SERVICE_GRANULARITY.md`).
    - Deploy readiness: the chart's `services:` values map already renders one Knative Service per key (`deploy/base/helmrelease.yaml`).
    - If/when building the add-service scaffolder: user preference is a **cargo-generate sub-template** rendered into `services/`; heavy shared-crate deps must move behind empty-default Cargo features; Dockerfile cargo-chef `cook`/`build` steps need `--bin <name>` scoping.
    - Known consideration (decision deferred, do not implement): kustomize Components cannot loop, so one-Canary-per-service means a scaffolder would need to emit `deploy/components/flagger/` Canaries or canary rendering moves into the Helm chart.
  - Anchor heading naming must let Task 3 and section 6 of the new doc reference `docs/TEMPLATE_GUIDE.md#multi-service-roadmap-notes`.

  **Must NOT do**:
  - Do NOT rewrite or reorganize either file beyond the specified insertion.
  - Do NOT add links inside `{% if %}` blocks in README.md.liquid.
  - Do NOT touch `docs/ARCHITECTURE.md` / `docs/KNATIVE_CONSTRAINTS.md` (no backlinks — scope locked).
  - Do NOT place the roadmap notes anywhere that ships to generated projects (TEMPLATE_GUIDE is generation-ignored — that is correct and intentional).

  **Recommended Agent Profile**:
  - **Category**: `quick` — two small, precisely-specified edits
  - **Skills**: `[]`
  - **Skills Evaluated but Omitted**: `git-master` (commit is Task 4's single atomic step, not per-task)

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Task 3)
  - **Blocks**: F1-F4 (and Task 4)
  - **Blocked By**: Task 1 (link target filename + anchor names are fixed by this plan; doc must exist so links aren't dead)

  **References**:
  - `README.md.liquid:331` and `:345` — exact existing cross-link phrasing pattern to imitate; also scan the file to identify unconditional (outside-`{% if %}`) regions for placement
  - `docs/TEMPLATE_GUIDE.md` — full read; it currently has NO docs index, so the new section is the anchor; match its existing section heading style
  - `cargo-generate.toml:11` — confirms TEMPLATE_GUIDE is generation-ignored (author-only)
  - `deploy/base/helmrelease.yaml:22-33` — source of truth for the `services:` map claim in the notes

  **WHY**: links make the doc discoverable; the roadmap notes preserve the consulted decisions (sub-template preference, deferred Canary question) so future template work doesn't re-litigate them.

  **Acceptance Criteria** (AGENT-EXECUTABLE VERIFICATION ONLY):

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Both links present (AC-5)
    Tool: Bash
    Steps:
      1. grep -n "SERVICE_GRANULARITY" README.md.liquid  → assert ≥ 1 match
      2. grep -n "SERVICE_GRANULARITY" docs/TEMPLATE_GUIDE.md  → assert ≥ 1 match
      3. grep -n "multi-service-roadmap-notes\|Multi-service roadmap notes" docs/TEMPLATE_GUIDE.md  → assert ≥ 1
    Expected Result: all greps non-empty
    Failure Indicators: any empty grep result
    Evidence: .sisyphus/evidence/task-2-link-checks.txt

  Scenario: README link is unconditional (placement check)
    Tool: Read + Bash
    Steps:
      1. Read README.md.liquid around the inserted line
      2. Locate the nearest enclosing {% if %} / {% endif %} pair (or confirm none)
      3. Assert the link line is NOT between any {% if %} and its {% endif %}
      4. Sanity: grep -n "{% if" README.md.liquid to map all conditional blocks first
    Expected Result: link line sits outside all Liquid conditionals (renders with --defaults / all-features-off)
    Failure Indicators: link found inside any {% if %}...{% endif %} range — the --defaults smoke test cannot catch this; this read-based check is the only guard
    Evidence: .sisyphus/evidence/task-2-placement-check.txt (paste relevant file lines)

  Scenario: README.md.liquid still valid Liquid
    Tool: Bash
    Steps:
      1. grep -c "{% if" README.md.liquid  (count before edit, recorded in evidence)
      2. grep -c "{% if" README.md.liquid  (count after edit)  → assert equal
      3. Same for "{% endif" and "{% raw"
    Expected Result: no conditional-block count changes; structure intact
    Failure Indicators: any count delta caused by the edit
    Evidence: .sisyphus/evidence/task-2-liquid-structure.txt
  ```

  **Evidence to Capture**: the 3 evidence files above

  **Commit**: NO (groups with Task 4)

- [ ] 3. Generation smoke test (AC-6 — the decisive test)

  **What to do**:
  Run a full template generation into a temp directory and assert the doc ships uncorrupted and the README link renders:
  1. `cargo generate --path . --name test-proj --defaults --allow-commands --destination /tmp/opencode/sg-test` (uses default placeholder values — all features off; `--name` pins the output dir name; `--allow-commands` is required because the post hook `post-generate.rhai` runs `cargo fmt`/clippy; hook may take minutes — allow a generous timeout)
  2. `test -f /tmp/opencode/sg-test/test-proj/docs/SERVICE_GRANULARITY.md`
  3. `grep -c "SERVICE_GRANULARITY" /tmp/opencode/sg-test/test-proj/docs/SERVICE_GRANULARITY.md` → ≥ 1 (heading survived)
  4. `grep -n "See \[docs/SERVICE_GRANULARITY.md\]" /tmp/opencode/sg-test/test-proj/README.md` → ≥ 1 (README link rendered; note `.liquid` suffix is stripped in output)
  5. `grep -n '{{' /tmp/opencode/sg-test/test-proj/docs/SERVICE_GRANULARITY.md` → zero matches (raw blocks consumed correctly, nothing mangled)
  6. `grep -rn "SERVICE_GRANULARITY" /tmp/opencode/sg-test/test-proj/cargo-generate.toml` → zero matches (generated project has no template config leftovers referencing it)
  7. Cleanup: `rm -rf /tmp/opencode/sg-test`
  If generation fails or the doc is corrupted: fix the doc's raw-block usage, re-run Task 1's Liquid-safety scenario, then re-run this task end-to-end.

  **Must NOT do**:
  - Do NOT "fix" generation issues by adding the doc to any ignore list (forbidden — see guardrails).
  - Do NOT commit temp artifacts or leave the temp dir behind.
  - Do NOT add a committed test script for this — ad-hoc commands only.

  **Recommended Agent Profile**:
  - **Category**: `quick` — scripted verification with exact commands
  - **Skills**: `[]`
  - **Skills Evaluated but Omitted**: `review`/`review-work` (overkill for a 3-file docs change; the AC list is the review)

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Task 2)
  - **Blocks**: F1-F4 (and Task 4)
  - **Blocked By**: Task 1 (doc must exist); independent of Task 2, but final pass gates the commit on both

  **References**:
  - `cargo-generate.toml:1-43` — template config: `subfolder = "."`, global ignore list, `[hooks] post = ["post-generate.rhai"]`, and the comment at lines 36-40 (ignored files deleted BEFORE hooks — explains why `--allow-commands` and hook runtime matter)
  - `post-generate.rhai` — what the post hook does (fmt/clippy); read to anticipate runtime and side effects on the generated tree
  - `Cargo.toml.liquid:1-12` — default placeholder values (`--defaults` → project name `example-app` etc.); note the destination subdir is named after the generated project name
  - AGENTS.md "Template Generation" section — background on generation flow and naming normalization

  **WHY**: this is the only test that catches Liquid corruption of a plain `.md` file; everything else is static analysis.

  **Acceptance Criteria** (AGENT-EXECUTABLE VERIFICATION ONLY):

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Happy path — generation ships doc + rendered link (AC-6)
    Tool: Bash
    Preconditions: Tasks 1-2 complete; /tmp/opencode exists (pre-created in this environment)
    Steps: exact steps 1-7 above, with per-step assertions recorded to evidence file
    Expected Result: all assertions pass; temp dir removed; exit 0 overall
    Failure Indicators: generation abort; doc missing from output; mangled braces in output; README link absent
    Evidence: .sisyphus/evidence/task-3-generation-smoke.txt

  Scenario: Negative — corrupted doc is detected (validates the test itself)
    Tool: Bash
    Preconditions: none (pure validation of detection logic, no repo changes)
    Steps:
      1. printf '# Test {{ project_name }}\n' > /tmp/opencode/liquid-corrupt-probe.md
      2. grep -n '{{' /tmp/opencode/liquid-corrupt-probe.md  → assert ≥ 1 match (detector works)
      3. rm /tmp/opencode/liquid-corrupt-probe.md
    Expected Result: grep finds the brace sequence (proves step-5 assertion above can actually fail)
    Failure Indicators: grep finds nothing — the Liquid-safety check would be vacuous
    Evidence: .sisyphus/evidence/task-3-negative-probe.txt
  ```

  **Evidence to Capture**: the 2 evidence files above

  **Commit**: NO (groups with Task 4)

- [ ] 4. Atomic commit (AFTER user okay on F1-F4)

  **What to do**:
  - Only after F1-F4 all APPROVE **and the user explicitly says okay**: commit exactly 3 files in one commit: `docs/SERVICE_GRANULARITY.md`, `README.md.liquid`, `docs/TEMPLATE_GUIDE.md`
  - Message: `docs: add service granularity decision framework and cross-links` (Conventional Commits per AGENTS.md)
  - Pre-commit: re-run Task 3's happy-path scenario if any doubt; `git status` must show nothing else staged
  - Post-commit: `git show --stat HEAD` → assert exactly 3 files; `git status` → clean

  **Must NOT do**:
  - Do NOT commit before user's explicit okay on the Final Verification Wave.
  - Do NOT split into multiple commits (doc without links is incomplete; links without doc are broken).
  - Do NOT include `.sisyphus/` files, evidence files, or any other stragglers.
  - Do NOT skip hooks or amend a failed commit (per AGENTS.md).

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: [`git-master`] — atomic commit discipline, staging exactly the 3 intended files
  - **Skills Evaluated but Omitted**: none applicable

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 3 (alone, after user okay)
  - **Blocks**: None
  - **Blocked By**: F1-F4 ALL APPROVE + explicit user okay

  **References**:
  - AGENTS.md "Commit Message Format" — Conventional Commits types; `docs` type with no scope matches examples
  - This plan's Commit Strategy section — exact message and file list

  **WHY**: the commit is the deliverable boundary; scope fidelity (F4) is only provable against a clean, exactly-3-files commit.

  **Acceptance Criteria** (AGENT-EXECUTABLE VERIFICATION ONLY):

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Commit contains exactly the 3 planned files
    Tool: Bash
    Preconditions: F1-F4 approved; user said okay
    Steps:
      1. git add docs/SERVICE_GRANULARITY.md README.md.liquid docs/TEMPLATE_GUIDE.md
      2. git status --short  → assert exactly these 3 staged, nothing else
      3. git commit -m "docs: add service granularity decision framework and cross-links"
      4. git show --stat HEAD  → assert exactly 3 files
      5. git status  → assert clean
    Expected Result: 3-file commit, clean tree
    Failure Indicators: extra files staged; commit hook rejection (fix and create new commit — do not amend)
    Evidence: .sisyphus/evidence/task-4-commit-stat.txt
  ```

  **Evidence to Capture**: `.sisyphus/evidence/task-4-commit-stat.txt`

  **Commit**: YES — `docs: add service granularity decision framework and cross-links`

---

## Final Verification Wave (MANDATORY — after ALL implementation tasks)

> 4 review agents run in PARALLEL. ALL must APPROVE. Present consolidated results to user and get explicit "okay" before committing (Task 4).
>
> **Do NOT auto-proceed after verification. Wait for user's explicit approval.**
> **Never mark F1-F4 as checked before getting user's okay.** Rejection or user feedback -> fix -> re-run -> present again -> wait for okay.

- [ ] F1. **Plan Compliance Audit** — `oracle`
  Read the plan end-to-end. For each "Must Have": verify it exists (grep the doc for AC-3 keywords, check README/TEMPLATE_GUIDE links). For each "Must NOT Have": search the diff for forbidden patterns — code file edits, ignore-list changes, scaffolder files, CHANGELOG entries, backlink edits to ARCHITECTURE/KNATIVE_CONSTRAINTS — reject with file:line if found. Check evidence files exist in `.sisyphus/evidence/`.
  Output: `Must Have [N/N] | Must NOT Have [N/N] | Tasks [N/N] | VERDICT: APPROVE/REJECT`

- [ ] F2. **Quality Review** — `unspecified-high`
  Docs-focused quality pass: read `docs/SERVICE_GRANULARITY.md` fully — check factual consistency with this plan (no invented Knative behavior), internal link validity (`grep -oP '\]\([^)]+\)' docs/SERVICE_GRANULARITY.md` and verify each target exists), heading hierarchy, and that brace sequences appear only inside `{% raw %}` blocks (`grep -n '{{\|{%' docs/SERVICE_GRANULARITY.md`). Repo sanity: `cargo check` passes, `git diff --stat` shows only the 3 expected files.
  Output: `Facts [N/N consistent] | Links [N/N valid] | Liquid [SAFE/UNSAFE] | Repo [CLEAN/N issues] | VERDICT`

- [ ] F3. **Full QA Re-run** — `unspecified-high`
  From clean state: execute EVERY QA scenario from Tasks 1-3 — exact steps, capture evidence to `.sisyphus/evidence/final-qa/`. Include the generation smoke test fresh (new temp dir, cleanup after). Assert AC-1 through AC-7 all green in one consolidated run.
  Output: `Scenarios [N/N pass] | ACs [7/7 green] | VERDICT`

- [ ] F4. **Scope Fidelity Check** — `deep`
  Read each task's "What to do" + actual `git diff`. Verify 1:1: everything specified was built (doc, 2 links, notes section), nothing beyond spec (no extra files, no doc sections beyond outline, no line-count gaming by truncating required content). Check "Must NOT do" compliance per task. Flag unaccounted changes (`git status`, untracked files).
  Output: `Tasks [N/N compliant] | Contamination [CLEAN/N issues] | Unaccounted [CLEAN/N files] | VERDICT`

---

## Commit Strategy

- **4** (after user okay on F1-F4): `docs: add service granularity decision framework and cross-links`
  - Files: `docs/SERVICE_GRANULARITY.md`, `README.md.liquid`, `docs/TEMPLATE_GUIDE.md` — exactly 3 files, atomic, never split
  - Pre-commit: all AC-1…AC-7 green (re-run Task 3 scenarios if any doubt)
  - Never commit with a failing AC-6 (generation smoke)

---

## Success Criteria

### Verification Commands
```bash
test -f docs/SERVICE_GRANULARITY.md                        # Expected: exit 0
wc -l docs/SERVICE_GRANULARITY.md                          # Expected: ≤ 300
grep -rn "SERVICE_GRANULARITY" cargo-generate.toml         # Expected: no matches (exit 1)
grep -n '{{\|{%' docs/SERVICE_GRANULARITY.md               # Expected: matches ONLY inside {% raw %} blocks
grep -n "SERVICE_GRANULARITY" README.md.liquid             # Expected: ≥ 1 match, outside {% if %} blocks
grep -n "SERVICE_GRANULARITY" docs/TEMPLATE_GUIDE.md       # Expected: ≥ 1 match
cargo check                                                # Expected: pass (sanity, no code changed)
```

### Final Checklist
- [ ] All "Must Have" present (AC-3 keyword coverage)
- [ ] All "Must NOT Have" absent
- [ ] Generation smoke test green (doc ships uncorrupted, README link renders)
- [ ] Atomic commit contains exactly 3 files
