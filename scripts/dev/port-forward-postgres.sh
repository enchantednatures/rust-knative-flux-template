#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
KUBECONFIG_PATH="${PROJECT_ROOT}/.kubeconfig-dev"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

if [[ ! -f "$KUBECONFIG_PATH" ]]; then
  echo -e "${RED}✗ Error: Kubeconfig not found at ${KUBECONFIG_PATH}${NC}"
  echo "Run 'make dev-cluster' first"
  exit 1
fi

export KUBECONFIG="$KUBECONFIG_PATH"

# Check if PostgreSQL cluster exists
if ! kubectl get cluster postgres-app -n default &>/dev/null; then
  echo -e "${RED}✗ Error: PostgreSQL cluster 'postgres-app' not found${NC}"
  echo "Run './scripts/dev/deploy-postgres.sh' first"
  exit 1
fi

echo -e "${GREEN}→${NC} Setting up port-forward to PostgreSQL..."
echo ""
echo "Primary (read-write) will be available at: localhost:5432"
echo "Press Ctrl+C to stop"
echo ""

kubectl port-forward -n default svc/postgres-app-rw 5432:5432
