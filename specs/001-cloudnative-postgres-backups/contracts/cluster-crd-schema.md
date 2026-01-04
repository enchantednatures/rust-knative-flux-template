# CloudNativePG Cluster CRD Schema

This document describes the key fields used in the CloudNativePG `Cluster` custom resource for deploying PostgreSQL with the Barman Cloud Plugin.

## Resource

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
```

## Key Fields

### metadata
- `name` (string, required): Cluster identifier (must be valid Kubernetes resource name per RFC 1123)
- `namespace` (string, optional): Kubernetes namespace (defaults to "default")

### spec

#### Instance Configuration
- `instances` (integer, required): Total number of PostgreSQL instances (primary + replicas)
  - Minimum: 1
  - Recommended: 1 (dev), 2 (staging), 3 (prod)

#### PostgreSQL Configuration
- `postgresql` (object, required):
  - `version` (string, required): PostgreSQL major version ("14", "15", "16")
  - `parameters` (map[string]string, optional): PostgreSQL configuration parameters
    - `shared_buffers`: Memory for shared buffers (e.g., "512MB")
    - `max_connections`: Maximum concurrent connections (e.g., "300")
    - `synchronous_commit`: Synchronization mode ("on", "remote_apply", "off")
    - `synchronous_standby_names`: Quorum configuration (e.g., "ANY 1 (*)")
    - `archive_timeout`: WAL archiving frequency (e.g., "5min")
    - `wal_compression`: Enable WAL compression ("on", "off")
  - `shared_preload_libraries` ([]string, optional): Extensions to preload (e.g., ["pg_stat_statements"])

#### Resources
- `resources` (object, optional):
  - `requests`:
    - `cpu` (string): CPU request (e.g., "500m", "1", "2")
    - `memory` (string): Memory request (e.g., "512Mi", "2Gi", "8Gi")
  - `limits`:
    - `cpu` (string): CPU limit (e.g., "1", "2", "4")
    - `memory` (string): Memory limit (e.g., "1Gi", "4Gi", "16Gi")

#### Storage
- `storage` (object, required):
  - `size` (string, required): Persistent volume size (e.g., "20Gi", "200Gi", "500Gi")
  - `storageClass` (string, optional): Kubernetes storage class name (must support ReadWriteOnce, minimum 3000 IOPS)

#### Plugin Configuration (Barman Cloud Plugin)
- `plugins` ([]object, required for backup):
  - `name` (string, required): Plugin identifier ("barman-cloud.cloudnative-pg.io")
  - `isWALArchiver` (boolean, required): Enable WAL archiving via plugin (true)
  - `parameters` (map[string]string, required):
    - `barmanObjectName` (string, required): Name of the `ObjectStore` CRD to use

#### Bootstrap (for restore operations)
- `bootstrap` (object, optional):
  - `recovery` (object): Restore from backup
    - `source` (string, required): Name of external cluster reference
    - `recoveryTarget` (object, optional):
      - `targetTime` (string): RFC 3339 timestamp for PITR (e.g., "2026-01-03T14:30:00Z")
  - `initdb` (object): Initialize new cluster
    - `postInitApplicationSQL` ([]string, optional): SQL to execute after init (e.g., ["CREATE EXTENSION pg_stat_statements;"])

#### External Clusters (for restore)
- `externalClusters` ([]object, optional):
  - `name` (string, required): Reference name
  - `plugin` (object, required):
    - `name` (string, required): Plugin identifier ("barman-cloud.cloudnative-pg.io")
    - `parameters` (map[string]string, required):
      - `barmanObjectName` (string, required): Name of the `ObjectStore` CRD
      - `serverName` (string, required): Source cluster name

#### Service Account
- `serviceAccountTemplate` (object, optional):
  - `metadata`:
    - `annotations` (map[string]string): Annotations for IRSA/Workload Identity
      - `eks.amazonaws.com/role-arn`: IAM role ARN for AWS IRSA (e.g., "arn:aws:iam::ACCOUNT:role/cnpg-backup-role")

## Connection Endpoints

Automatically created by the operator:

- **Primary (Read-Write)**: `<cluster-name>-rw.<namespace>.svc.cluster.local`
- **Replicas (Read-Only)**: `<cluster-name>-ro.<namespace>.svc.cluster.local`
- **Any instance**: `<cluster-name>-r.<namespace>.svc.cluster.local`

## State Transitions

- `creating` → `ready` (successful deployment)
- `creating` → `failed` (deployment error)
- `ready` → `updating` (configuration change)
- `updating` → `ready` (update complete)
- `ready` → `switchover` (manual failover triggered)
- `switchover` → `ready` (new primary elected)
- `ready` → `fenced` (cluster fenced due to split-brain detection)

## Validation Rules

- `instances` must be at least 1
- For production (synchronous_commit = remote_apply), `instances` should be ≥ 3
- `storage.size` must accommodate actual data + WAL files + 20% growth buffer
- `resources.limits.memory` must be at least 2x `resources.requests.memory`
- `resources.limits.cpu` must be at least 1x `resources.requests.cpu`
- When using plugin for backups, `plugins[].name` must be "barman-cloud.cloudnative-pg.io"
- Plugin parameters must reference a valid `ObjectStore` CRD via `barmanObjectName`

## References

- [CloudNativePG Cluster API Reference](https://cloudnative-pg.io/documentation/current/api_reference/)
- [Barman Cloud Plugin Documentation](https://cloudnative-pg.io/plugin-barman-cloud/docs/intro/)
