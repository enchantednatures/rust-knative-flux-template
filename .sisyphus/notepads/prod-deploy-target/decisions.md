# Decisions — prod-deploy-target

## 2026-09-08 Interview
- Standalone make prod-deploy (independent of bootstrap)
- Deploy key: auto-detect auth failure → flux create secret git → print pubkey → POLL non-interactive (5m); first run fails by design; NEVER rotate existing secret
- git-repository.yaml: SSH URL + always-on secretRef github-deploy-key
- Tests: in-cluster detached-pod curl; health smoke suite only (4 checks)
- Kubeconfig: KUBECONFIG env → .kubeconfig-prod file; prod-kubeconfig helper target
- No image builds; Flux image automation owns tags
- GHA: in-cluster ARC runner + RBAC (SA scoped to flux-system + production only); tag v* + workflow_dispatch; branch-policy-only protection
- prod-github-env: dedicated local-only target via gh api
