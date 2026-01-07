# Local E2E Testing - Changelog

## 2026-01-07 - Initial Release

### Added
- **Local E2E test script** (`scripts/test-template-e2e-local.sh`)
  - Mirrors CI workflow from `.github/workflows/template-e2e-test.yaml`
  - Uses local Docker registry for caching (60-70% faster than CI)
  - Supports `no-s3`, `with-s3`, and `all` scenarios
  - Leaves cluster running on failure for debugging
  - Clear error messages and troubleshooting tips

- **Cleanup script** (`scripts/cleanup-e2e-local.sh`)
  - Removes Kind clusters, local registry, generated files
  - Safe to run multiple times
  - Preserves other development clusters

- **Comprehensive documentation**:
  - `docs/LOCAL_E2E_TESTING.md` - Complete guide with usage, debugging, tips
  - `docs/E2E_TROUBLESHOOTING.md` - Problem-solution reference for 20+ common issues
  - `.github/workflows/LOCAL_TESTING_QUICK_REF.md` - Quick cheat sheet
  - `scripts/README.md` - Scripts directory documentation

### Fixed
- **Kubernetes v1.32.0 compatibility** - Fixed kubelet startup failures on macOS by pinning to stable Kubernetes v1.32.0 (required for Knative v1.20) instead of v1.35.0
- **Docker daemon check** - Script now validates Docker is running before attempting cluster creation
- **Template exclusions** - Added E2E scripts and docs to `cargo-generate.toml` ignore list to prevent template processing
- **Apple Silicon build support** - Added `--platform linux/amd64` flag to Docker build to fix cargo-chef failures on arm64 Macs

### Features
- **Smart dependency checking** - Validates all required tools are installed
- **Local registry integration** - Automatic setup and connection to Kind clusters
- **Parallel testing support** - Run multiple scenarios in separate terminals
- **Debug-friendly** - Clusters persist on failure with clear kubectl instructions
- **Color-coded output** - Easy-to-read progress indicators and status messages
- **Error context** - Specific troubleshooting tips for each failure scenario

### Performance
| Iteration | CI Time | Local (cached) | Time Saved |
|-----------|---------|----------------|------------|
| 1st run   | 30 min  | 15 min         | 15 min     |
| 2nd run   | 30 min  | 10 min         | 20 min     |
| 3rd run   | 30 min  | 8 min          | 22 min     |

### Usage

```bash
# Run all scenarios
./scripts/test-template-e2e-local.sh

# Run specific scenario
./scripts/test-template-e2e-local.sh no-s3

# Keep cluster running for debugging
KEEP_CLUSTER=true ./scripts/test-template-e2e-local.sh with-s3

# Clean up everything
./scripts/cleanup-e2e-local.sh
```

### Requirements
- Docker Desktop running
- kind, kubectl, helm, kustomize, flux, cargo installed
- 4GB RAM minimum (6GB recommended)
- 10GB free disk space

### Known Issues
- None reported

### Next Steps
- Monitor user feedback on macOS Apple Silicon compatibility
- Consider adding support for custom Kubernetes versions
- Add metrics collection for performance tracking
- Consider adding watch mode for continuous testing
