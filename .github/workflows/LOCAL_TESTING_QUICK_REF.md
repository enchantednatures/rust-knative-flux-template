# Quick Reference: Local E2E Testing

This is a quick reference for running E2E tests locally instead of waiting for CI.

## 🚀 Quick Start

```bash
# Run all scenarios
./scripts/test-template-e2e-local.sh

# Run specific scenario
./scripts/test-template-e2e-local.sh no-s3
./scripts/test-template-e2e-local.sh with-s3

# Clean up everything
./scripts/cleanup-e2e-local.sh
```

## 📋 Prerequisites (macOS)

```bash
brew install docker kind kubectl helm kustomize fluxcd/tap/flux
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

## 🐛 Debugging Failed Tests

When tests fail, the cluster stays running:

```bash
# Use kubeconfig from script output
export KUBECONFIG=/tmp/kind-kubeconfig-no-s3

# Check pods
kubectl get pods -A

# View logs
kubectl logs -l serving.knative.dev/service=rust-service --tail=100

# Check Flux
flux get all -A

# Describe service
kubectl describe ksvc/rust-service
```

## 🧹 Keep Cluster for Debugging

```bash
KEEP_CLUSTER=true ./scripts/test-template-e2e-local.sh no-s3
```

## ⏱️ Time Comparison

| Environment | Duration |
|-------------|----------|
| CI (GitHub Actions) | ~30 minutes |
| Local (first run) | ~15-20 minutes |
| Local (cached) | ~8-12 minutes |

## 💡 Tips

1. **Cache everything**: Keep Docker running between test runs
2. **Test before PR**: Run locally to catch issues early
3. **Parallel testing**: Run both scenarios in separate terminals
4. **Clean up regularly**: `./scripts/cleanup-e2e-local.sh` to free disk space

## 📚 Full Documentation

See [docs/LOCAL_E2E_TESTING.md](../../docs/LOCAL_E2E_TESTING.md) for complete guide.
