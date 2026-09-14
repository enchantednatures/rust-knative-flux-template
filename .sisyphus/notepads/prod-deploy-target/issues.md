# Issues — prod-deploy-target

## 2026-09-08 Known Gaps (from Metis review)
- No production Namespace resource exists anywhere in deploy/ (fixed by Task 2)
- Flagger dependsOn unsatisfied in prod config (pre-flight check in Task 3)
- Makefile lacks GITHUB_ORG/GITHUB_REPO vars (Task 3)
- .gitignore missing .kubeconfig-prod (Task 3)

## 2026-09-08 Task 1 discovery
- BLOCKER for harness green state: `kustomize build deploy/overlays/prod` fails TODAY on ALL combos (kustomize 5.8.1 AND kubectl's bundled version) with "wrong node kind: expected ScalarNode but got MappingNode" — the inline strategic-merge patch on `spec.values.services."":` (empty-string key) vs base HelmRelease fails to merge. Dev overlay fails identically. Isolated cause: the `patches:` block (build passes with it removed). NO plan task owns this fix — Tasks 2-6 edits alone won't make the overlays/prod build assertion green. Likely fix: convert prod overlay SMP patch to JSON6902 (or restructure the `services.""` patch) — needs orchestrator decision (probably fold into Task 2 or 3).
- Minor: post-generate hook prints "⚠️ clippy --fix failed / cargo fmt failed (non-blocking)" warnings in every generated project when run without --allow-commands — cosmetic noise in harness logs, generation still exits 0.
