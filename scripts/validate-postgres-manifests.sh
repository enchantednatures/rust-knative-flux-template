#!/bin/bash

# Script: Validate PostgreSQL manifest syntax
# Purpose: Verify all PostgreSQL YAML manifests are valid Kubernetes resources
# Usage: ./validate-postgres-manifests.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== PostgreSQL Manifest Validation ==="
echo ""

ERRORS=0
WARNINGS=0

# Find all PostgreSQL manifests
echo "Scanning for PostgreSQL manifests..."
MANIFESTS=$(find "$REPO_ROOT/deploy" -name "*.yaml" -o -name "*.yml" | grep -E "(postgres|objectstore|backup)" | sort)

echo "Found $(echo "$MANIFESTS" | wc -l) PostgreSQL manifests"
echo ""

# Validate each manifest
for MANIFEST in $MANIFESTS; do
    echo "Validating: $MANIFEST"
    
    # Use kubectl dry-run to validate syntax
    if kubectl apply -f "$MANIFEST" --dry-run=client -o yaml > /dev/null 2>&1; then
        echo "  ✓ Valid"
    else
        echo "  ✗ ERROR: Invalid manifest syntax"
        kubectl apply -f "$MANIFEST" --dry-run=client -o yaml 2>&1 | head -20
        ((ERRORS++))
    fi
done

echo ""
echo "=== Kustomization Validation ==="
echo ""

# Validate kustomizations
KUSTOMIZATIONS=(
    "$REPO_ROOT/deploy/base"
    "$REPO_ROOT/deploy/overlays/dev"
    "$REPO_ROOT/deploy/overlays/staging"
    "$REPO_ROOT/deploy/overlays/prod"
)

for KUSTOMIZATION in "${KUSTOMIZATIONS[@]}"; do
    if [ -f "$KUSTOMIZATION/kustomization.yaml" ]; then
        echo "Validating: $KUSTOMIZATION"
        
        if kubectl kustomize "$KUSTOMIZATION" --dry-run=client > /dev/null 2>&1; then
            echo "  ✓ Valid"
        else
            echo "  ✗ ERROR: Invalid kustomization"
            kubectl kustomize "$KUSTOMIZATION" 2>&1 | head -20
            ((ERRORS++))
        fi
    fi
done

echo ""
echo "=== Build Validation ==="
echo ""

# Test building complete overlays
echo "Building dev overlay..."
BUILT_MANIFESTS=$(kubectl kustomize "$REPO_ROOT/deploy/overlays/dev" 2>&1)
if [ $? -eq 0 ]; then
    echo "✓ Dev overlay builds successfully"
    # Count resources
    RESOURCE_COUNT=$(echo "$BUILT_MANIFESTS" | grep "^kind:" | wc -l)
    echo "  Resources in dev overlay: $RESOURCE_COUNT"
else
    echo "✗ ERROR: Dev overlay build failed"
    ((ERRORS++))
fi

echo ""
echo "Building staging overlay..."
BUILT_MANIFESTS=$(kubectl kustomize "$REPO_ROOT/deploy/overlays/staging" 2>&1)
if [ $? -eq 0 ]; then
    echo "✓ Staging overlay builds successfully"
else
    echo "✗ ERROR: Staging overlay build failed"
    ((ERRORS++))
fi

echo ""
echo "Building prod overlay..."
BUILT_MANIFESTS=$(kubectl kustomize "$REPO_ROOT/deploy/overlays/prod" 2>&1)
if [ $? -eq 0 ]; then
    echo "✓ Prod overlay builds successfully"
else
    echo "✗ ERROR: Prod overlay build failed"
    ((ERRORS++))
fi

echo ""
echo "=== Schema Validation ==="
echo ""

# Check for common issues
echo "Checking for common manifest issues..."

# Check for required CloudNativePG CRDs referenced
REQUIRED_APIS=(
    "postgresql.cnpg.io"
    "objectstorage.cnpg.io"
)

for API in "${REQUIRED_APIS[@]}"; do
    if grep -r "group: $API\|apiVersion.*$API" "$REPO_ROOT/deploy" > /dev/null; then
        echo "✓ $API resources found in manifests"
    fi
done

echo ""
echo "=== Validation Summary ==="
echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✓ All manifests valid!"
    echo ""
    echo "Validation Results:"
    echo "  Files validated: $(echo "$MANIFESTS" | wc -l)"
    echo "  Kustomizations: 4"
    echo "  Errors: 0"
    echo "  Warnings: $WARNINGS"
    echo ""
    echo "Ready to deploy!"
    exit 0
else
    echo "✗ Validation failed with $ERRORS error(s)"
    echo ""
    echo "Validation Results:"
    echo "  Errors: $ERRORS"
    echo "  Warnings: $WARNINGS"
    echo ""
    echo "Please fix errors above before deploying."
    exit 1
fi
