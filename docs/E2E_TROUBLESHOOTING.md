# E2E Testing Troubleshooting

Quick troubleshooting guide for local E2E testing issues.

## Docker Daemon Not Running

**Error:**
```
✗ Docker daemon is not running
failed to connect to the docker API at unix:///Users/.../.docker/run/docker.sock
```

**Solution:**
1. **macOS:** Open Docker Desktop from Applications
2. **Linux:** `sudo systemctl start docker`
3. Wait for Docker to fully start (check the menu bar icon)
4. Verify: `docker ps` should work without errors
5. Re-run the E2E script

## Port 5001 Already in Use

**Error:**
```
Error starting userland proxy: listen tcp4 0.0.0.0:5001: bind: address already in use
```

**Solution:**
```bash
# Find what's using port 5001
lsof -i :5001

# If it's the old registry, stop it
docker stop kind-registry-e2e
docker rm kind-registry-e2e

# Or use a different port (edit the script)
LOCAL_REGISTRY="localhost:5002"
```

## Kind Cluster Creation Fails (Kubelet Unhealthy)

**Error:**
```
ERROR: failed to create cluster: failed to init node with kubeadm
[kubelet-check] The kubelet is not healthy after 4m0s
```

**Cause:**
This is often caused by Kubernetes v1.35+ compatibility issues on macOS or resource constraints.

**Solution:**
The script uses Kubernetes v1.32.0 by default (required for Knative v1.20, stable on macOS). If you still see this error:

```bash
# 1. Clean up any partial clusters
kind delete cluster --name e2e-no-s3
kind delete cluster --name e2e-with-s3

# 2. Restart Docker Desktop
# macOS: Quit and restart Docker Desktop

# 3. Increase Docker Desktop resources
# Docker Desktop → Preferences → Resources
# - Memory: 4GB minimum (6GB recommended)
# - CPUs: 2 minimum (4 recommended)

# 4. Clean Docker system
docker system prune -f

# 5. Try again
./scripts/test-template-e2e-local.sh
```

## Kind Cluster Already Exists

**Error:**
```
ERROR: failed to create cluster: cluster already exists
```

**Solution:**
```bash
# Delete existing cluster
kind delete cluster --name e2e-no-s3
kind delete cluster --name e2e-with-s3

# Or use cleanup script
./scripts/cleanup-e2e-local.sh
```

## Out of Disk Space

**Error:**
```
no space left on device
```

**Solution:**
```bash
# Clean up Docker resources
docker system prune -a -f

# Clean up E2E artifacts
./scripts/cleanup-e2e-local.sh

# Remove unused volumes
docker volume prune -f
```

## cargo-generate Not Found

**Error:**
```
cargo-generate: command not found
```

**Solution:**
```bash
# Install cargo-generate
cargo install cargo-generate --locked

# Or let the script install it automatically
./scripts/test-template-e2e-local.sh
```

## Knative Service Not Ready

**Symptom:**
Test fails at "Waiting for Knative Service to be ready..."

**Debug:**
```bash
# Use the kubeconfig from script output
export KUBECONFIG=/tmp/kind-kubeconfig-no-s3

# Check pod status
kubectl get pods -n default

# View logs
kubectl logs -l serving.knative.dev/service=rust-service

# Check pod events
kubectl describe pod -l serving.knative.dev/service=rust-service

# Check if image was loaded
docker images | grep test-app
kind get nodes --name e2e-no-s3 | xargs -I {} docker exec {} crictl images | grep test-app
```

## Flux Reconciliation Failed

**Symptom:**
OCIRepository or Kustomization not ready

**Debug:**
```bash
export KUBECONFIG=/tmp/kind-kubeconfig-no-s3

# Check Flux resources
flux get all -A

# Check OCIRepository
kubectl describe ocirepository/test-app-no-s3 -n flux-system

# Check Kustomization
kubectl describe kustomization/test-app-no-s3 -n flux-system

# View Flux logs
kubectl logs -n flux-system deployment/source-controller --tail=50
kubectl logs -n flux-system deployment/kustomize-controller --tail=50
```

## Local Registry Connection Issues

**Symptom:**
Cannot push/pull images to/from localhost:5001

**Debug:**
```bash
# Check registry is running
docker ps | grep kind-registry-e2e

# Test registry connectivity
curl http://localhost:5001/v2/_catalog

# Check Kind network
docker network inspect kind | grep kind-registry-e2e

# Reconnect registry to Kind network
docker network connect kind kind-registry-e2e
```

## Helm Install Timeout

**Symptom:**
Redis or MinIO installation times out

**Debug:**
```bash
export KUBECONFIG=/tmp/kind-kubeconfig-no-s3

# Check pod status
kubectl get pods -A

# Check events
kubectl get events --sort-by='.lastTimestamp' | tail -20

# View pod logs
kubectl logs -l app.kubernetes.io/name=redis
kubectl logs -l app=minio

# Increase timeout and retry
helm install redis bitnami/redis --wait --timeout 300s
```

## Network Issues in Kind

**Symptom:**
Pods can't reach each other or external services

**Debug:**
```bash
export KUBECONFIG=/tmp/kind-kubeconfig-no-s3

# Test DNS resolution
kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup kubernetes.default

# Test pod-to-pod connectivity
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- curl http://redis-master:6379

# Check CoreDNS
kubectl logs -n kube-system -l k8s-app=kube-dns
```

## Script Hangs or Stalls

**Symptom:**
Script stops progressing without error

**Debug:**
```bash
# Run with bash tracing
bash -x ./scripts/test-template-e2e-local.sh no-s3

# Check for hanging kubectl waits
ps aux | grep kubectl

# Kill stuck processes
pkill kubectl

# Start fresh
./scripts/cleanup-e2e-local.sh
./scripts/test-template-e2e-local.sh
```

## Rust Build Failures in Docker

**Symptom:**
Docker build fails during Rust compilation or cargo-chef cook

**Error:**
```
ERROR: failed to build: process "/bin/sh -c cargo chef cook --release --target x86_64-unknown-linux-musl --recipe-path recipe.json" did not complete successfully: exit code: 101
```

**Cause:**
Platform mismatch when building on Apple Silicon (arm64) for x86_64 target.

**Solution:**
The script now includes `--platform linux/amd64` flag. If you still see errors:

```bash
# Build manually with platform flag
cd ./generated/test-app-no-s3
docker build --platform linux/amd64 -t test .

# Check Docker buildx is available
docker buildx version

# If buildx not available, enable it in Docker Desktop
# Docker Desktop → Settings → Features in development → Enable buildx
```

**Debug:**
```bash
# Build manually to see full output
cd ./generated/test-app-no-s3
docker build --platform linux/amd64 -t test .

# Check Dockerfile
cat Dockerfile

# Try without cache
docker build --platform linux/amd64 --no-cache -t test .

# Check Cargo.toml dependencies
cat Cargo.toml
```

## Permission Denied Errors

**Symptom:**
Permission denied accessing Docker socket or files

**Solution:**
```bash
# macOS: Add user to docker group (usually not needed)
# Linux: Add user to docker group
sudo usermod -aG docker $USER
newgrp docker

# Or run with sudo (not recommended)
sudo ./scripts/test-template-e2e-local.sh
```

## Memory/CPU Pressure

**Symptom:**
System becomes slow or unresponsive

**Solution:**
1. Close unnecessary applications
2. Run one scenario at a time (not in parallel)
3. Increase Docker Desktop memory limits:
   - Docker Desktop → Preferences → Resources
   - Increase Memory to at least 4GB
4. Use lighter scenarios (no-s3 uses less resources)

## Clean Slate Approach

When all else fails:

```bash
# 1. Clean up everything
./scripts/cleanup-e2e-local.sh

# 2. Remove all Docker resources
docker system prune -a -f
docker volume prune -f

# 3. Restart Docker Desktop
# macOS: Quit and restart Docker Desktop
# Linux: sudo systemctl restart docker

# 4. Verify Docker is healthy
docker run hello-world

# 5. Try again
./scripts/test-template-e2e-local.sh no-s3
```

## Getting More Help

If issues persist:

1. **Enable verbose output:**
   ```bash
   bash -x ./scripts/test-template-e2e-local.sh no-s3 2>&1 | tee debug.log
   ```

2. **Collect diagnostic info:**
   ```bash
   docker version
   kind version
   kubectl version
   uname -a
   df -h
   docker info
   ```

3. **Check system resources:**
   ```bash
   # macOS
   top -l 1 | head -n 10
   
   # Linux
   free -h
   df -h
   ```

4. **Compare with CI:**
   - Check `.github/workflows/template-e2e-test.yaml`
   - Look for differences in versions or configuration
   - Compare CI logs with local output

5. **Open an issue:**
   - Include script output
   - Include diagnostic info
   - Include any error messages
   - Describe what you've tried

## Version Compatibility

### Kubernetes and Knative Versions

The E2E test script uses:
- **Kubernetes v1.32.0** - Required for Knative v1.20.0 (minimum v1.32)
- **Knative v1.20.0** - Latest stable release

These versions are tested and stable on macOS (including Apple Silicon).

**Do not use:**
- Kubernetes v1.35+ - Has kubelet stability issues on macOS
- Kubernetes v1.30-v1.31 - Not compatible with Knative v1.20

If you need to test with different versions, ensure compatibility:
- Knative v1.19 requires Kubernetes v1.30-v1.31
- Knative v1.20+ requires Kubernetes v1.32+

## Common Gotchas

### 1. Docker Desktop Updates
After updating Docker Desktop, you may need to:
- Restart Docker
- Recreate Kind clusters
- Clear Docker cache

### 2. macOS Rosetta on Apple Silicon
If running on M1/M2 Mac:
- Ensure Docker Desktop is running native (not Rosetta)
- Check: `docker info | grep Architecture` should show `arm64`

### 3. VPN/Firewall Issues
Some corporate VPNs interfere with:
- Docker networking
- Kind cluster creation
- Image registry access

Try disconnecting VPN if issues occur.

### 4. Stale Kubeconfig
If kubectl commands fail:
```bash
# Remove stale kubeconfigs
rm -f /tmp/kind-kubeconfig-*
rm -f ~/.kube/config

# Let script regenerate
./scripts/test-template-e2e-local.sh
```

### 5. Helm Repository Issues
If helm install fails:
```bash
# Update helm repos
helm repo update

# Or remove and re-add
helm repo remove bitnami
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
```
