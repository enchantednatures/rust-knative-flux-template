#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
KUBECONFIG_PATH="${PROJECT_ROOT}/.kubeconfig-dev"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

TOPIC="events"
MESSAGE="${1:-Hello from Kafka!}"

if [[ ! -f "$KUBECONFIG_PATH" ]]; then
  echo -e "${RED}✗ Error: Kubeconfig not found${NC}"
  echo "Run 'make dev-cluster' first"
  exit 1
fi

export KUBECONFIG="$KUBECONFIG_PATH"

echo -e "${BLUE}Sending message to Kafka topic: ${GREEN}${TOPIC}${NC}"
echo -e "${YELLOW}Message:${NC} $MESSAGE"
echo ""

# Generate CloudEvent as JSON
EVENT_ID="event-$(date +%s%N | md5sum | cut -c1-8)"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Create CloudEvent in structured format
CLOUDEVENT=$(cat <<EOF
{
  "specversion": "1.0",
  "type": "com.example.kafka.event",
  "source": "/scripts/kafka-producer",
  "id": "$EVENT_ID",
  "time": "$TIMESTAMP",
  "datacontenttype": "application/json",
  "data": {
    "message": "$MESSAGE"
  }
}
EOF
)

echo -e "${YELLOW}→${NC} Producing to Kafka..."

# Use kubectl exec to produce message
kubectl -n kafka exec -i kafka-0 -- kafka-console-producer \
  --bootstrap-server localhost:9092 \
  --topic "$TOPIC" <<< "$CLOUDEVENT"

echo ""
echo -e "${GREEN}✓ Event sent successfully${NC}"
echo -e "${YELLOW}Event ID:${NC} ${EVENT_ID}"
echo ""
echo -e "${BLUE}To view service logs:${NC}"
echo "  make dev-logs"
