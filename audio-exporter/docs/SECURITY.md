# Security Guide

Security best practices and hardening guide for audio-exporter.

## Table of Contents

- [Security Principles](#security-principles)
- [Container Security](#container-security)
- [Kubernetes Security](#kubernetes-security)
- [Secret Management](#secret-management)
- [API Security](#api-security)
- [Network Security](#network-security)
- [Supply Chain Security](#supply-chain-security)
- [Compliance](#compliance)
- [Security Checklist](#security-checklist)

---

## Security Principles

### Defense in Depth

Multiple layers of security:
1. **Container Layer**: Non-root, minimal image
2. **Kubernetes Layer**: RBAC, NetworkPolicy
3. **Application Layer**: Input validation, error handling
4. **Network Layer**: TLS, mTLS
5. **Infrastructure Layer**: AWS/Azure/GCP security

### Least Privilege

- Only grant necessary permissions
- Use service accounts with minimal scope
- Restrict network access via policies

### Zero Trust

- Verify all network requests
- Assume network is compromised
- Encrypt all data in transit

---

## Container Security

### Dockerfile Best Practices

**Current Dockerfile** (`Dockerfile`):
```dockerfile
# Multi-stage build
FROM rust:1.92 AS builder
WORKDIR /app
COPY . .
RUN cargo build --release

# Minimal runtime image
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/audio-exporter /usr/local/bin/audio-exporter

# Non-root user
RUN useradd -r -s /bin/false appuser
USER appuser

# Read-only root filesystem
RUN chmod 555 /etc /usr /bin /lib

EXPOSE 8080
CMD ["audio-exporter"]
```

### Security Features

#### 1. Non-Root User

**Why**: Prevents privilege escalation vulnerabilities

```dockerfile
RUN useradd -r -s /bin/false appuser
USER appuser
```

**Verification**:
```bash
docker run --rm your-image whoami
# Output: appuser
```

#### 2. Minimal Base Image

**Why**: Reduces attack surface

✅ **Good**:
```dockerfile
FROM debian:bookworm-slim
FROM alpine:3.19
FROM scratch  # Best for compiled languages
```

❌ **Bad**:
```dockerfile
FROM debian:latest  # Too many packages
FROM ubuntu:latest  # Too many packages
```

#### 3. Read-Only Root Filesystem

**Why**: Prevents runtime modifications

```yaml
# deploy/base/knative-service.yaml
spec:
  template:
    spec:
      containers:
      - name: user-container
        securityContext:
          readOnlyRootFilesystem: true
        volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
  - name: tmp
    emptyDir: {}
```

#### 4. No Privileged Containers

```yaml
securityContext:
  privileged: false
  allowPrivilegeEscalation: false
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
```

#### 5. Drop All Capabilities

```yaml
securityContext:
  capabilities:
    drop:
    - ALL
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
```

### Container Image Scanning

**Trivy**:
```bash
# Install Trivy
brew install trivy  # macOS
apt install trivy   # Ubuntu

# Scan image
trivy image ghcr.io/enchantednatures/audio-exporter:latest

# Scan with severity filter
trivy image --severity HIGH,CRITICAL ghcr.io/enchantednatures/audio-exporter:latest
```

**Grype**:
```bash
# Install Grype
brew install grype  # macOS

# Scan image
grype ghcr.io/enchantednatures/audio-exporter:latest
```

**CI Integration** (`.github/workflows/security-scan.yaml`):
```yaml
name: Security Scan

on: [push, pull_request]

jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
    
    - name: Build image
      run: docker build -t test-image .
    
    - name: Run Trivy
      uses: aquasecurity/trivy-action@master
      with:
        image-ref: test-image
        format: 'sarif'
        output: 'trivy-results.sarif'
        severity: 'HIGH,CRITICAL'
    
    - name: Upload Trivy Results
      uses: github/codeql-action/upload-sarif@v2
      with:
        sarif_file: 'trivy-results.sarif'
```

### Container Signatures

**Sign with Cosign**:
```bash
# Install Cosign
go install github.com/sigstore/cosign/cmd/cosign@latest

# Sign image
cosign sign --key cosign.key ghcr.io/enchantednatures/audio-exporter:v1.0.0

# Verify signature
cosign verify --key cosign.pub ghcr.io/enchantednatures/audio-exporter:v1.0.0

# Verify in Kubernetes (Admission Controller)
# Kyverno Policy to enforce signature verification
```

---

## Kubernetes Security

### RBAC (Role-Based Access Control)

**Create Service Account**:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: audio-exporter
  namespace: audio-exporter
```

**Create Role**:
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: audio-exporter
  namespace: audio-exporter
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get"]
  resourceNames: ["audio-exporter-secrets"]
```

**Create RoleBinding**:
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: audio-exporter
  namespace: audio-exporter
subjects:
- kind: ServiceAccount
  name: audio-exporter
roleRef:
  kind: Role
  name: audio-exporter
  apiGroup: rbac.authorization.k8s.io
```

### Pod Security Standards

**Baseline Profile**:
```yaml
spec:
  template:
    metadata:
      labels:
        pod-security.kubernetes.io/enforce: baseline
        pod-security.kubernetes.io/audit: baseline
        pod-security.kubernetes.io/warn: baseline
    spec:
      containers:
      - name: user-container
        securityContext:
          runAsNonRoot: true
          runAsUser: 1000
          runAsGroup: 1000
          readOnlyRootFilesystem: true
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
```

**Restricted Profile** (stricter):
```yaml
        pod-security.kubernetes.io/enforce: restricted
        pod-security.kubernetes.io/audit: restricted
        pod-security.kubernetes.io/warn: restricted
```

### Network Policies

**Allow Only Ingress from Knative Gateway**:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: audio-exporter-network-policy
  namespace: audio-exporter
spec:
  podSelector:
    matchLabels:
      serving.knative.dev/service: audio-exporter
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: knative-serving
    ports:
    - protocol: TCP
      port: 8080
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: audio-exporter
    ports:
    - protocol: TCP
      port: 6379  # Redis

    - to:
      - namespaceSelector: {}
    ports:
    - protocol: TCP
      port: 443  # S3 over HTTPS

```

**Deny All (Default Deny)**:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: audio-exporter
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
```

### Security Context

**Pod Level**:
```yaml
spec:
  template:
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
```

**Container Level**:
```yaml
        containers:
        - name: user-container
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
              - ALL
            readOnlyRootFilesystem: true
```

---

## Secret Management

### Never Commit Secrets

❌ **Bad**:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-secrets
type: Opaque
stringData:
  password: "super-secret-password"  # DON'T DO THIS
```

✅ **Good**: Use Kubernetes Secrets

```bash
kubectl create secret generic audio-exporter-secrets \
  --from-literal=redis-url='redis://redis:6379' \
  --from-literal=aws-access-key-id='YOUR_KEY' \
  --from-literal=aws-secret-access-key='YOUR_SECRET' \
  
```

### External Secrets Operator

**AWS Secrets Manager**:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: aws-secrets-manager
  namespace: audio-exporter
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: audio-exporter
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: audio-exporter-secrets
  namespace: audio-exporter
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: SecretStore
  target:
    name: audio-exporter-secrets
    creationPolicy: Owner
  data:
  - secretKey: redis-url
    remoteRef:
      key: /audio-exporter/production/redis-url
  
  - secretKey: aws-access-key-id
    remoteRef:
      key: /audio-exporter/production/aws-access-key-id
  - secretKey: aws-secret-access-key
    remoteRef:
      key: /audio-exporter/production/aws-secret-access-key
  
```

**IAM Role for Service Account (IRSA)**:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: audio-exporter
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT_ID:role/audio-exporter-role
```

**AWS IAM Policy**:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue"
      ],
      "Resource": "arn:aws:secretsmanager:REGION:ACCOUNT_ID:secret:/audio-exporter/*"
    }
  ]
}
```

### Sealed Secrets (GitOps)

**Encrypt Secret**:
```bash
# Install kubeseal
brew install kubeseal  # macOS

# Encrypt secret
echo -n "my-password" | kubectl create secret generic my-secret \
  --dry-run=client \
  --from-file=/dev/stdin \
  -o yaml | kubeseal > my-secret.sealed.yaml

# Commit to Git
git add my-secret.sealed.yaml
git commit -m "Add sealed secret"
```

**Deploy**:
```bash
kubectl apply -f my-secret.sealed.yaml
# Sealed Secrets controller decrypts automatically
```

### Secret Rotation

**Automated Rotation** (AWS Secrets Manager):
```yaml
# deploy/flux/external-secret.yaml
spec:
  refreshInterval: 1h  # Check every hour
```

**Manual Rotation**:
```bash
# Update secret in AWS Secrets Manager
aws secretsmanager update-secret \
  --secret-id /audio-exporter/production/redis-url \
  --secret-string 'redis://new-redis:6379'

# External Secrets Operator syncs automatically
# Kubernetes pods need restart to pick up new secret
kubectl rollout restart deployment/audio-exporter -n audio-exporter
```

---

## API Security

### Input Validation

**Path Parameters**:
```rust
use axum::{extract::Path, Json, response::IntoResponse};
use regex::Regex;

pub async fn get_user(Path(user_id): Path<String>) -> Result<Json<User>, AppError> {
    // Validate UUID format
    let uuid_regex = Regex::new(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")?;
    
    if !uuid_regex.is_match(&user_id) {
        return Err(AppError::BadRequest("Invalid user ID format".to_string()));
    }
    
    // Fetch user
    Ok(Json(fetch_user(&user_id).await?))
}
```

**Request Body Validation**:
```rust
use serde::{Deserialize, Validate};
use validator::Validate;

#[derive(Deserialize, Validate)]
pub struct UploadRequest {
    #[validate(length(min = 1, max = 255))]
    key: String,
    
    #[validate(custom = "validate_base64")]
    data: String,
}

fn validate_base64(data: &str) -> Result<(), validator::ValidationError> {
    base64::decode(data).map_err(|_| {
        validator::ValidationError::new("invalid_base64")
    })?;
    Ok(())
}

pub async fn upload(
    Json(req): Json<UploadRequest>,
) -> Result<StatusCode, AppError> {
    req.validate()?;
    // ... upload logic
}
```

### Rate Limiting

**Tower-Governor**:
```bash
# Add to Cargo.toml
[dependencies]
tower-governor = "0.1"
governor = "0.5"
```

```rust
use tower_governor::{Governor, GovernorConfigBuilder};

// Create governor config
let governor_conf = Box::new(
    GovernorConfigBuilder::default()
        .per_second(10)
        .burst_size(30)
        .finish()
        .unwrap(),
);

// Apply to router
let app = Router::new()
    .route("/api/upload", post(upload_handler))
    .layer(Governor::new(&governor_conf));
```

### CSRF Protection

**For State-Changing Operations**:
```rust
use axum::{extract::State, response::IntoResponse};
use axum_csrf::CsrfToken;

pub async fn upload_with_csrf(
    State(state): State<AppState>,
    token: CsrfToken,
) -> impl IntoResponse {
    // Verify token
    token.verify().await?;
    
    // Process upload
    // ...
}
```

---

## Network Security

### TLS/HTTPS

**Knative with Cert-Manager**:
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: audio-exporter-cert
  namespace: audio-exporter
spec:
  secretName: audio-exporter-tls
  dnsNames:
  - audio-exporter.example.com
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
```

**Enforce HTTPS**:
```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: audio-exporter
spec:
  template:
    metadata:
      annotations:
        networking.knative.dev/http-protocol: "h2c"  # HTTP/2
        networking.knative.dev/external-traffic-policy: "Local"
```

### Service Mesh (Istio/Cilium)

**mTLS Between Services**:
```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: audio-exporter
  namespace: audio-exporter
spec:
  selector:
    matchLabels:
      serving.knative.dev/service: audio-exporter
  mtls:
    mode: STRICT
```

**Network Policy with Cilium**:
```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: audio-exporter
  namespace: audio-exporter
spec:
  endpointSelector:
    matchLabels:
      app: audio-exporter
  ingress:
  - fromEntities:
    - world
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
      rules:
        http:
          - method: "GET"
            path: "/health/.*"
```

---

## Supply Chain Security

### Dependency Auditing

**cargo-audit**:
```bash
# Install
cargo install cargo-audit

# Run audit
cargo audit

# Audit with database update
cargo audit --fetch
```

**CI Integration**:
```yaml
- name: Security Audit
  run: cargo audit
```

### Signed Commits

**Enable Commit Signing**:
```bash
# Setup GPG signing
git config --global commit.gpgsign true
git config --global gpg.program gpg

# Sign commit
git commit -S -m "feat: add feature"

# Verify
git log --show-signature
```

**Enforce in GitHub**:
- Settings → Actions → General
- Require signed commits

### Reproducible Builds

**Docker Layer Caching**:
```yaml
# Build CI workflow
- name: Build image
  uses: docker/build-push-action@v5
  with:
    cache-from: type=gha
    cache-to: type=gha,mode=max
```

**SBOM (Software Bill of Materials)**:
```bash
# Install Syft
brew install syft  # macOS

# Generate SBOM
syft your-image:latest -o spdx-json > sbom.json
```

---

## Compliance

### Data Retention


**S3 Bucket Lifecycle**:
```bash
# Set lifecycle policy
aws s3api put-bucket-lifecycle-configuration \
  --bucket audio-exporter-data \
  --lifecycle-configuration file://lifecycle.json
```

`lifecycle.json`:
```json
{
  "Rules": [
    {
      "ID": "DeleteAfter90Days",
      "Status": "Enabled",
      "Expiration": {
        "Days": 90
      }
    }
  ]
}
```

**Encryption at Rest**:
```bash
# Enable bucket encryption
aws s3api put-bucket-encryption \
  --bucket audio-exporter-data \
  --server-side-encryption-configuration '{
    "Rules": [
      {
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "AES256"
        }
      }
    ]
  }'
```


### Audit Logging

**Kubernetes Audit Log**:
```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: RequestResponse
  resources:
  - group: ""
    resources: ["secrets"]
- level: Request
  resources:
  - group: ""
    resources: ["configmaps"]
```

**Application Audit Log**:
```rust
use tracing::{info, instrument};

#[instrument(fields(user_id = %user.id, action = "upload"))]
pub async fn upload_handler(user: User, file: File) -> Result<(), AppError> {
    info!("User {} uploaded file {}", user.id, file.name);
    // ... upload logic
}
```

---

## Security Checklist

### Pre-Production

- [ ] Container image scanned (Trivy/Grype)
- [ ] Image signed (Cosign)
- [ ] Dependencies audited (cargo-audit)
- [ ] Secrets not in Git
- [ ] RBAC configured (least privilege)
- [ ] Network policies applied
- [ ] TLS enabled
- [ ] Input validation implemented
- [ ] Rate limiting configured
- [ ] Logging/monitoring enabled
- [ ] Alerting configured
- [ ] Security review completed

### Production

- [ ] Regular security scans (weekly)
- [ ] Monthly dependency updates
- [ ] Quarterly penetration testing
- [ ] Annual security audit
- [ ] Incident response plan tested
- [ ] Backup encryption enabled
- [ ] Disaster recovery tested
- [ ] Access review (quarterly)

---

## Next Steps

- **Development**: See `docs/DEVELOPMENT.md`
- **Deployment**: See `docs/DEPLOYMENT.md`
- **Monitoring**: See `docs/MONITORING.md`
- **Troubleshooting**: See `docs/TROUBLESHOOTING.md`
