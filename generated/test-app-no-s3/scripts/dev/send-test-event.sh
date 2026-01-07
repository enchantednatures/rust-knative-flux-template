#!/bin/bash
set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SERVICE_HOST="${1:-localhost:8080}"
EVENT_TYPE="${2:-com.example.ping}"
MESSAGE="${3:-Hello from CloudEvent!}"

echo -e "${BLUE}Sending CloudEvent to: ${GREEN}${SERVICE_HOST}${NC}"
echo ""
echo -e "${YELLOW}Event Details:${NC}"
echo "  Type: $EVENT_TYPE"
echo "  Source: /demo/test-script"
echo "  Message: $MESSAGE"
echo ""

# Generate a unique event ID
EVENT_ID="event-$(date +%s%N | md5sum | cut -c1-8)"

# Send the CloudEvent
echo -e "${YELLOW}→${NC} Sending event..."
RESPONSE=$(curl -s -X POST "http://${SERVICE_HOST}/" \
  -H "ce-specversion: 1.0" \
  -H "ce-type: ${EVENT_TYPE}" \
  -H "ce-source: /demo/test-script" \
  -H "ce-id: ${EVENT_ID}" \
  -H "ce-time: $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -H "Content-Type: application/json" \
  -d "{\"message\": \"${MESSAGE}\"}")

# Display response
echo ""
echo -e "${YELLOW}→${NC} Response:"
echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"
echo ""
echo -e "${GREEN}✓ Event sent successfully${NC}"
echo ""
echo -e "${YELLOW}Event ID:${NC} ${EVENT_ID}"
