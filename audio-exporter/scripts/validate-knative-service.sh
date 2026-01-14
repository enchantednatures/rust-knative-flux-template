#!/bin/bash
set -euo pipefail

# ============================================================================
# Knative Service Validator
# ============================================================================
# Validates Knative Service manifests against known constraints and best practices
# This script catches configuration errors before deployment to prevent
# timeouts and deployment failures.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

ERRORS=0
WARNINGS=0

# Helper functions
error() {
  echo -e "${RED}✗ ERROR${NC}: $*" >&2
  ((ERRORS++))
}

warning() {
  echo -e "${YELLOW}⚠ WARNING${NC}: $*" >&2
  ((WARNINGS++))
}

success() {
  echo -e "${GREEN}✓${NC} $*"
}

info() {
  echo -e "${BLUE}ℹ${NC} $*"
}

# Check if required tools are available
check_tools() {
  info "Checking required tools..."
  
  local tools=("kubectl" "kustomize" "yq")
  for tool in "${tools[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
      error "Required tool not found: $tool"
    fi
  done
}

# Validate kustomize builds without errors
validate_kustomize() {
  local overlay_path="$1"
  
  # Skip if this is a template directory (contains .liquid files)
  if ls "$overlay_path"/*.yaml.liquid &>/dev/null 2>&1; then
    info "Skipping template overlay (liquid files): $overlay_path"
    return 0
  fi
  
  info "Validating kustomize build for: $overlay_path"
  
  if ! kubectl kustomize "$overlay_path" > /dev/null 2>&1; then
    error "Kustomize build failed for: $overlay_path"
    kubectl kustomize "$overlay_path" 2>&1 | sed 's/^/  /' || true
    return 1
  fi
  success "Kustomize build valid: $overlay_path"
}

# Check for unsupported Knative fields
validate_knative_fields() {
  local base_path="$1"
  
  # Find manifest files (could be .yaml or .yaml.liquid)
  local manifest_file
  if [[ -f "${base_path}/knative-service.yaml" ]]; then
    manifest_file="${base_path}/knative-service.yaml"
  elif [[ -f "${base_path}/knative-service.yaml.liquid" ]]; then
    manifest_file="${base_path}/knative-service.yaml.liquid"
  else
    info "No knative-service manifest found in $base_path"
    return 0
  fi
  
  info "Checking for unsupported Knative fields..."
  
  # fieldRef is not supported in Knative
  if grep -q "fieldRef:" "$manifest_file"; then
    error "Found unsupported 'fieldRef' in environment variables. Knative does not allow fieldRef - use static values instead."
    return 1
  fi
  success "No unsupported fieldRef found"
}

# Check for read-only filesystem with no tmpfs
validate_security_context() {
  local base_path="$1"
  
  # Find manifest files
  local manifest_file
  if [[ -f "${base_path}/knative-service.yaml" ]]; then
    manifest_file="${base_path}/knative-service.yaml"
  elif [[ -f "${base_path}/knative-service.yaml.liquid" ]]; then
    manifest_file="${base_path}/knative-service.yaml.liquid"
  else
    return 0
  fi
  
  info "Checking security context configuration..."
  
  # If readOnlyRootFilesystem is true, ensure tmpfs volume is mounted
  if grep -q "readOnlyRootFilesystem: true" "$manifest_file"; then
    if ! grep -q "emptyDir:" "$manifest_file"; then
      error "Found readOnlyRootFilesystem: true but no emptyDir volume for /tmp. Add volumeMount and volume for /tmp."
      return 1
    fi
    success "Read-only filesystem properly configured with tmpfs volume"
  else
    warning "readOnlyRootFilesystem not set to true - consider enabling for security"
  fi
}

# Check namespace configuration
validate_namespace() {
  local overlay_path="$1"
  info "Checking namespace configuration..."
  
  local kustomization="${overlay_path}/kustomization.yaml"
  if [[ ! -f "$kustomization" ]]; then
    kustomization="${overlay_path}/kustomization.yaml.liquid"
  fi
  
  # Check if this is a dev overlay
  if [[ "$overlay_path" == *"dev"* ]]; then
    if grep -q "^namespace:" "$kustomization" 2>/dev/null; then
      warning "Dev overlay has hardcoded namespace - E2E tests may fail when using -n flag. Consider removing namespace from dev overlay."
    else
      success "Dev overlay has no hardcoded namespace (good for flexibility)"
    fi
  else
    # Production and staging should have namespaces
    if ! grep -q "^namespace:" "$kustomization" 2>/dev/null; then
      warning "Production/Staging overlay missing namespace - specify one for clarity"
    else
      success "Namespace properly configured for overlay"
    fi
  fi
}

# Check health probes configuration
validate_health_probes() {
  local base_path="$1"
  
  # Find manifest files
  local manifest_file
  if [[ -f "${base_path}/knative-service.yaml" ]]; then
    manifest_file="${base_path}/knative-service.yaml"
  elif [[ -f "${base_path}/knative-service.yaml.liquid" ]]; then
    manifest_file="${base_path}/knative-service.yaml.liquid"
  else
    return 0
  fi
  
  info "Checking health probe configuration..."
  
  if ! grep -q "readinessProbe:" "$manifest_file"; then
    error "No readinessProbe found - service may be marked ready before dependencies are available"
    return 1
  fi
  success "Readiness probe configured"
  
  if ! grep -q "livenessProbe:" "$manifest_file"; then
    warning "No liveness probe found - pod won't be restarted if it hangs"
  else
    success "Liveness probe configured"
  fi
}

# Check for deprecated kustomize fields
validate_kustomize_deprecations() {
  local overlay_path="$1"
  info "Checking for deprecated kustomize fields..."
  
  local kustomization="${overlay_path}/kustomization.yaml"
  if [[ ! -f "$kustomization" ]]; then
    kustomization="${overlay_path}/kustomization.yaml.liquid"
  fi
  
  if grep -q "^bases:" "$kustomization" 2>/dev/null; then
    error "Found deprecated 'bases' field - use 'resources' instead"
    return 1
  fi
  success "No deprecated 'bases' field found"
  
  if grep -q "^commonLabels:" "$kustomization" 2>/dev/null; then
    error "Found 'commonLabels' - this auto-adds spec.selector to Services which breaks Knative. Remove it."
    return 1
  fi
  success "No problematic commonLabels found"
}

# Check memory and CPU limits
validate_resources() {
  local base_path="$1"
  
  # Find manifest files
  local manifest_file
  if [[ -f "${base_path}/knative-service.yaml" ]]; then
    manifest_file="${base_path}/knative-service.yaml"
  elif [[ -f "${base_path}/knative-service.yaml.liquid" ]]; then
    manifest_file="${base_path}/knative-service.yaml.liquid"
  else
    return 0
  fi
  
  info "Checking resource limits..."
  
  if ! grep -q "memory:" "$manifest_file"; then
    error "No memory limits specified - pod could consume excessive memory"
    return 1
  fi
  
  if ! grep -q "cpu:" "$manifest_file"; then
    error "No CPU limits specified - pod could consume excessive CPU"
    return 1
  fi
  success "Resource limits properly configured"
}

# Check environment variables
validate_environment() {
  local base_path="$1"
  
  # Find manifest files
  local manifest_file
  if [[ -f "${base_path}/knative-service.yaml" ]]; then
    manifest_file="${base_path}/knative-service.yaml"
  elif [[ -f "${base_path}/knative-service.yaml.liquid" ]]; then
    manifest_file="${base_path}/knative-service.yaml.liquid"
  else
    return 0
  fi
  
  info "Checking environment variables..."
  
  # Check if required Redis URL is configured
  if ! grep -q "APP__REDIS__URL\|REDIS_URL" "$manifest_file"; then
    error "Redis URL environment variable not configured - readiness probe will fail"
    return 1
  fi
  success "Redis URL configured"
  
  # Check for hardcoded static values instead of fieldRef
  if grep -q "APP__TELEMETRY__SERVICE_NAME" "$manifest_file"; then
    if grep -A 1 "APP__TELEMETRY__SERVICE_NAME" "$manifest_file" | grep -q "value:"; then
      success "Telemetry service name uses static value (good for Knative)"
    fi
  fi
}

# Main validation
main() {
  echo ""
  echo "=========================================="
  echo "  Knative Service Validator"
  echo "=========================================="
  echo ""
  
  check_tools
  
  if [[ $ERRORS -gt 0 ]]; then
    echo ""
    echo -e "${RED}Tool check failed${NC}"
    return 1
  fi
  
  # Find all kustomization overlays
  local   overlays=(
    "deploy/overlays/dev"
    "deploy/overlays/staging"
    "deploy/overlays/prod"
  )
  
  echo ""
  for overlay in "${overlays[@]}"; do
    overlay_path="${PROJECT_ROOT}/${overlay}"
    if [[ -d "$overlay_path" ]]; then
      echo ""
      echo "Validating overlay: $overlay"
      echo "---"
      
      validate_kustomize "$overlay_path" || ((ERRORS++))
      local base_dir=$(dirname "$(dirname "$overlay_path")")/base
      validate_knative_fields "$base_dir" || ((ERRORS++))
      validate_kustomize_deprecations "$overlay_path" || ((ERRORS++))
      validate_namespace "$overlay_path" || ((ERRORS++))
      validate_security_context "$base_dir" || ((ERRORS++))
      validate_health_probes "$base_dir" || ((ERRORS++))
      validate_resources "$base_dir" || ((ERRORS++))
      validate_environment "$base_dir" || ((ERRORS++))
    fi
  done
  
  echo ""
  echo "=========================================="
  echo "  Validation Summary"
  echo "=========================================="
  echo -e "Errors:   ${RED}${ERRORS}${NC}"
  echo -e "Warnings: ${YELLOW}${WARNINGS}${NC}"
  echo ""
  
  if [[ $ERRORS -gt 0 ]]; then
    echo -e "${RED}✗ Validation FAILED${NC}"
    return 1
  else
    echo -e "${GREEN}✓ Validation PASSED${NC}"
    return 0
  fi
}

main "$@"
