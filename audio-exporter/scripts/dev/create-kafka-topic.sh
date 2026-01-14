#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
KUBECONFIG_PATH="${PROJECT_ROOT}/.kubeconfig-dev"

TOPIC="${1:-}"
PARTITIONS="${2:-3}"
REPLICATION="${3:-1}"

if [[ ! -f "$KUBECONFIG_PATH" ]]; then
  echo -e "${RED}✗ Error: Kubeconfig not found${NC}"
  echo "Run 'make dev-cluster' first"
  exit 1
fi

if [ -z "$TOPIC" ]; then
  echo "Usage: $0 <topic-name> [partitions] [replication-factor]"
  echo "Example: $0 my-topic 6 1"
  exit 1
fi

export KUBECONFIG="$KUBECONFIG_PATH"

echo "Creating Kafka topic: $TOPIC"
echo "  Partitions: $PARTITIONS"
echo "  Replication factor: $REPLICATION"

kubectl -n kafka exec -it kafka-0 -- kafka-topics \
  --bootstrap-server localhost:9092 \
  --create \
  --if-not-exists \
  --topic "$TOPIC" \
  --partitions "$PARTITIONS" \
  --replication-factor "$REPLICATION"

echo "✓ Topic created successfully"
echo ""
echo "List all topics:"
kubectl -n kafka exec -it kafka-0 -- kafka-topics \
  --bootstrap-server localhost:9092 \
  --list
