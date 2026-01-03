# Barman Cloud Plugin ObjectStore CRD Schema

This document describes the `ObjectStore` custom resource for configuring Barman Cloud Plugin backup storage.

## Resource

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
```

## Key Fields

### metadata
- `name` (string, required): ObjectStore identifier (referenced by Cluster and ScheduledBackup)
- `namespace` (string, optional): Kubernetes namespace (defaults to "default")

### spec

#### configuration (object, required)
Configuration for object storage backend and backup behavior.

##### destinationPath (string, required)
- S3 URI for backup storage location
- Format: `s3://bucket-name/path/prefix/`
- Examples:
  - `s3://postgres-backups/` (root of bucket)
  - `s3://backups/postgres/cluster-name/` (with prefix)
- Must end with trailing slash

##### endpointURL (string, optional)
- Custom S3-compatible endpoint URL
- Required for: MinIO, Ceph RGW, non-AWS S3 providers
- Omit for AWS S3 (uses default regional endpoint)
- Examples:
  - `http://minio:9000` (MinIO in-cluster)
  - `https://s3.custom-provider.com` (external S3-compatible)

##### endpointCA (object, optional)
Custom CA certificate for HTTPS endpoints with self-signed certificates.
- `name` (string): Name of ConfigMap containing CA certificate
- `key` (string): Key in ConfigMap containing PEM-encoded certificate

##### s3Credentials (object, required)
Reference to Kubernetes Secret containing S3 credentials.

**accessKeyId** (object, required):
- `name` (string): Secret name
- `key` (string): Key in secret containing access key ID

**secretAccessKey** (object, required):
- `name` (string): Secret name
- `key` (string): Key in secret containing secret access key

**sessionToken** (object, optional):
- `name` (string): Secret name
- `key` (string): Key in secret containing session token (for temporary credentials)

**region** (string, optional):
- AWS region for S3 bucket (e.g., "us-east-1", "eu-west-1")
- Omit for non-AWS providers

**Note**: For production environments using AWS, consider using IRSA (IAM Roles for Service Accounts) instead of static credentials. Configure via `serviceAccountTemplate` in Cluster CRD.

##### data (object, optional)
Configuration for base backup compression.

- `compression` (string, optional): Compression algorithm
  - Options: `gzip`, `bzip2`, `snappy`, `zstd`, `none`
  - Default: `gzip`
  - Recommended: `gzip` (dev/staging), `zstd` (production - faster, better compression)
- `jobs` (integer, optional): Number of parallel compression threads
  - Default: 2
  - Range: 1-8
  - Higher values = faster compression but more CPU usage
- `encryption` (string, optional): Encryption method
  - Options: `AES256` (SSE-S3), `aws:kms` (SSE-KMS)
  - Default: None (recommended to use S3 server-side encryption instead)

##### wal (object, optional)
Configuration for Write-Ahead Log (WAL) archiving.

- `compression` (string, optional): WAL compression algorithm
  - Options: Same as `data.compression`
  - Default: `gzip`
  - Recommended: `gzip` (balance of speed and compression)
- `encryption` (string, optional): WAL encryption method
  - Options: Same as `data.encryption`
- `maxParallel` (integer, optional): Parallel WAL fetches during restore
  - Default: 1
  - Range: 1-8
  - Higher values = faster restore but more network/CPU usage

##### tags (map[string]string, optional)
Custom tags to apply to S3 objects (for cost allocation, compliance tracking).

Example:
```yaml
tags:
  environment: production
  team: platform
  cost-center: engineering
```

#### retentionPolicy (string, required)
Automatic deletion policy for old backups.

- Format: `<number><unit>` where unit is `d` (days), `w` (weeks), `m` (months)
- Examples:
  - `7d` - Keep backups for 7 days (development)
  - `14d` - Keep backups for 14 days (staging)
  - `30d` - Keep backups for 30 days (production)
  - `3m` - Keep backups for 90 days (compliance)
- Minimum: `1d`
- Note: At least one backup will always be retained regardless of age

## Connection Patterns

### Referenced by Cluster (WAL archiving)
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
spec:
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: minio-dev  # References ObjectStore by name
```

### Referenced by ScheduledBackup
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
spec:
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
    parameters:
      barmanObjectName: minio-dev  # References ObjectStore by name
```

### Referenced by External Cluster (restore)
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
spec:
  externalClusters:
    - name: backup-source
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: s3-prod  # References ObjectStore by name
          serverName: original-cluster-name
```

## Secret Format

The referenced Kubernetes Secret must contain base64-encoded credentials:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: minio-credentials
  namespace: default
type: Opaque
data:
  ACCESS_KEY_ID: <base64-encoded-access-key>
  ACCESS_SECRET_KEY: <base64-encoded-secret-key>
```

For SOPS encryption in Git:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: minio-credentials
  namespace: default
type: Opaque
stringData:  # SOPS encrypts stringData fields
  ACCESS_KEY_ID: minioadmin
  ACCESS_SECRET_KEY: minioadmin
```

## Validation Rules

- `destinationPath` must be a valid S3 URI starting with `s3://`
- `destinationPath` must end with trailing slash (`/`)
- `s3Credentials` must reference an existing Secret in the same namespace
- `retentionPolicy` must be at least `1d`
- `data.jobs` and `wal.maxParallel` must be between 1 and 8
- Compression values must be one of: `gzip`, `bzip2`, `snappy`, `zstd`, `none`
- When using AWS S3 (no `endpointURL`), `s3Credentials.region` should be specified

## Performance Recommendations

### Development/Staging
- `data.compression: gzip` (simpler, widely compatible)
- `data.jobs: 2` (balanced performance)
- `wal.compression: gzip`
- `wal.maxParallel: 2`

### Production
- `data.compression: zstd` (faster compression, better ratios)
- `data.jobs: 4` (utilize more CPU for faster backups)
- `wal.compression: gzip` (balance for frequent archiving)
- `wal.maxParallel: 4` (faster restore operations)

### High-Write Workloads
- Increase `wal.maxParallel` to 8 for faster restore
- Consider `wal.compression: snappy` (fastest, moderate compression)
- Ensure network bandwidth supports WAL archiving rate

## Security Recommendations

1. **Credentials Management**:
   - Use SOPS + Age for encrypting secrets in Git
   - Rotate credentials every 90 days
   - For AWS production, use IRSA instead of static credentials

2. **Encryption**:
   - Enable S3 server-side encryption (SSE-S3 or SSE-KMS)
   - Use `encryption: AES256` in ObjectStore spec for additional layer
   - For compliance, use KMS keys with audit logging

3. **Access Control**:
   - Apply least-privilege IAM policies (backup service needs PutObject, GetObject, DeleteObject)
   - Restore operations need GetObject only
   - Use separate IAM roles for backup (read-write) and restore (read-only)

4. **Network Security**:
   - Use HTTPS endpoints (`https://`) for external providers
   - For internal MinIO, use HTTP only in development
   - Add custom CA certificates via `endpointCA` for private CAs

## References

- [Barman Cloud Plugin Documentation](https://cloudnative-pg.io/plugin-barman-cloud/docs/intro/)
- [ObjectStore API Reference](https://cloudnative-pg.io/plugin-barman-cloud/docs/api_reference/)
- [Barman Cloud Configuration](https://pgbarman.org/documentation/)
