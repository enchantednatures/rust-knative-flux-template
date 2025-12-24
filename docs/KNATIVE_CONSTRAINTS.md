# Knative Serving Constraints & Best Practices

This document outlines Knative-specific constraints, limitations, and best practices to prevent common deployment failures.

## Running Local Validation

Before deploying, always run the validation script to catch configuration errors early:

```bash
./scripts/validate-knative-service.sh
```

This script checks for:
- ✓ Unsupported field references (fieldRef)
- ✓ Invalid kustomize configurations  
- ✓ Missing security contexts
- ✓ Insufficient resource limits
- ✓ Missing health probes

---

## Knative Field Constraints

### ❌ NOT Allowed: `valueFrom.fieldRef`

Knative does **not** allow environment variables to use `fieldRef` for dynamic pod metadata.

**Problem:**
```yaml
env:
  - name: POD_NAME
    valueFrom:
      fieldRef:
        fieldPath: metadata.name  # ❌ NOT supported by Knative
```

**Solution:** Use static values instead
```yaml
env:
  - name: SERVICE_NAME
    value: "rust-service"  # ✓ Static values work fine
```

**Why:** Knative has strict requirements on what can be configured in the pod template. Use Knative's built-in service discovery features for service names.

---

### ❌ NOT Allowed: `spec.selector` in Services

When using Kustomize, the `commonLabels` field auto-generates `spec.selector` which breaks Knative Services (Knative manages selectors internally).

**Problem:**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

commonLabels:  # ❌ Will add spec.selector to Service
  app: my-app
```

**Error:**
```
error when creating Service: Service in version "v1" cannot be handled as a Service: 
strict decoding error: unknown field "spec.selector"
```

**Solution:** Remove `commonLabels` from kustomization files
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# Remove commonLabels! ✓
resources:
  - knative-service.yaml
```

**Why:** Knative Services handle their own label selectors. Labels should be defined directly in the Service manifest, not via Kustomize's commonLabels.

---

### ❌ RISKY: Read-Only Root Filesystem Without tmpfs

Setting `readOnlyRootFilesystem: true` is good for security, but requires a writable `/tmp` volume.

**Problem:**
```yaml
securityContext:
  readOnlyRootFilesystem: true  # ✓ Good for security
  # ❌ But no emptyDir for /tmp = pod startup fails
```

**Error:** Pod fails readiness check because it can't write temporary files.

**Solution:** Add emptyDir volume for /tmp
```yaml
securityContext:
  readOnlyRootFilesystem: true  # ✓ Secure
volumeMounts:
  - name: tmp
    mountPath: /tmp
volumes:
  - name: tmp
    emptyDir: {}  # ✓ Provides writable /tmp
```

**Why:** Applications need to write temp files, logs, and socket files. emptyDir is ephemeral per-pod, so it doesn't violate the read-only filesystem security goal.

---

##Namespace Configuration

### Dev Overlay: Omit Namespace

Dev overlays should **not** specify a namespace to allow flexibility for E2E tests.

**Good:**
```yaml
# examples/deploy/overlays/dev/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base
  # No namespace: allows -n flag in kubectl
```

**Problem:** Hardcoded namespace prevents `kubectl apply -k ... -n test-app`
```
error: the namespace from the provided object "default" does not match 
the namespace "test-app"
```

### Staging/Production: Require Namespace

Always specify namespaces for production overlays.

```yaml
# examples/deploy/overlays/prod/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: production  # ✓ Explicit namespace

resources:
  - ../../base
```

---

## YAML Indentation in Patches

JSON merge patches in Kustomize are sensitive to YAML indentation. All list items must have consistent indentation.

**Problem:**
```yaml
patches:
  - target:
      kind: Service
      name: rust-service
    patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/resources/limits/cpu
        value: "1000m"
       - op: replace  # ❌ ONE extra space breaks the patch!
         path: /spec/template/spec/containers/0/resources/limits/memory
         value: "512Mi"
```

**Error:**
```
unable to parse SM or JSON patch from [patch: ...]
```

**Solution:** Ensure all list items have identical indentation
```yaml
      - op: replace
        path: /spec/template/spec/containers/0/resources/limits/cpu
        value: "1000m"
      - op: replace  # ✓ Consistent 6-space indentation
        path: /spec/template/spec/containers/0/resources/limits/memory
        value: "512Mi"
```

Run the validation script to catch these automatically!

---

## Health Probes Configuration

Always configure both liveness and readiness probes.

### Readiness Probe (Required for Knative)

Readiness probes must pass before traffic is routed to the service.

```yaml
readinessProbe:
  httpGet:
    path: /health/ready
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 2
```

**Key points:**
- **initialDelaySeconds:** Allow time for application startup and dependency connections
- **periodSeconds:** Check frequently enough to catch failures
- **failureThreshold:** Low threshold (2) prevents traffic to unhealthy pods

### Liveness Probe (Recommended)

Liveness probes restart pods that are stuck.

```yaml
livenessProbe:
  httpGet:
    path: /health/live
    port: 8080
  initialDelaySeconds: 3
  periodSeconds: 10
  timeoutSeconds: 2
  failureThreshold: 3
```

**Key points:**
- **initialDelaySeconds:** Shorter than readiness - process is already up
- **failureThreshold:** Higher threshold (3) prevents flapping restarts
- **Should NOT check dependencies** - only confirm the process is running

---

## Resource Requests and Limits

Always specify both requests and limits for CPU and memory.

```yaml
resources:
  requests:
    cpu: "100m"
    memory: "64Mi"
  limits:
    cpu: "500m"
    memory: "256Mi"
```

**Why:**
- **Requests:** Kubernetes uses these for scheduling
- **Limits:** Prevents pod from consuming all node resources
- **Both required:** For predictable auto-scaling and node utilization

---

## Deprecated Kustomize Fields

The validation script checks for deprecated fields. Migrate these:

### ❌ `bases:` → ✓ `resources:`

```yaml
# Old (deprecated)
bases:
  - ../../base

# New (correct)
resources:
  - ../../base
```

### ❌ `commonLabels:` → ✓ Define in Manifest

```yaml
# Old (problematic with Knative)
commonLabels:
  app: my-service

# New (define in Service directly)
# metadata:
#   labels:
#     app: my-service
```

---

## Common Failure Patterns

### Timeout Waiting for Service to be Ready

**Symptoms:**
```
error: timed out waiting for the condition on services/rust-service
```

**Usual Causes:**
1. **Readiness probe failing** - check pod logs
2. **Dependencies unavailable** - verify Redis/S3 connectivity
3. **Missing /tmp volume** - with read-only root filesystem
4. **Security context issues** - insufficient permissions

**Diagnosis:**
```bash
# Check pod status
kubectl get pods -n test-app

# View pod logs
kubectl logs -n test-app -l serving.knative.dev/service=rust-service

# Check service status
kubectl describe ksvc rust-service -n test-app

# Test readiness manually
kubectl exec -it <pod> -- curl http://localhost:8080/health/ready
```

### Kustomize Build Failures

**Symptoms:**
```
unable to parse SM or JSON patch
error: trouble configuring builtin PatchTransformer
```

**Usual Causes:**
1. **YAML indentation** - inconsistent spaces in patches
2. **Missing or extra fields** - typos in patch paths
3. **Invalid base paths** - kustomization can't find base resources

**Solution:** Run validation script
```bash
./scripts/validate-knative-service.sh
```

---

## Security Hardening Checklist

- [ ] `runAsNonRoot: true` - Don't run as root
- [ ] `runAsUser: 10001` - Use unprivileged user ID
- [ ] `readOnlyRootFilesystem: true` - Immutable code
- [ ] `emptyDir` for `/tmp` - Writable temporary storage
- [ ] `drop: ALL` capabilities - Remove dangerous capabilities
- [ ] Resource limits - Prevent resource exhaustion
- [ ] Health probes - Detect and restart failures
- [ ] Image scanning - Validate base images

---

## Useful References

- [Knative Serving Runtime Contract](https://knative.dev/docs/serving/runtime-contract/)
- [Kustomize Documentation](https://kustomize.io/)
- [Kubernetes Security Best Practices](https://kubernetes.io/docs/concepts/security/)
- [JSON Patch RFC](https://tools.ietf.org/html/rfc6902)
