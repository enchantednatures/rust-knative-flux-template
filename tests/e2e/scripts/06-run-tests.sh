#!/bin/bash
set -euo pipefail

SCENARIO="${1}"
INCLUDE_S3="${2}"

# Use scenario-specific kubeconfig
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${SCRIPT_DIR}/.kubeconfig-${SCENARIO}"

if [[ ! -f "$KUBECONFIG" ]]; then
  echo "Error: Kubeconfig not found: $KUBECONFIG"
  echo "Did you run 00-setup-kind.sh first?"
  exit 1
fi

echo "Getting Knative Service URL..."
SERVICE_URL=$(kubectl get ksvc rust-service -n test-app -o jsonpath='{.status.url}')
echo "Service URL: ${SERVICE_URL}"

# Helper function for tests
run_test() {
  local name="$1"
  local cmd="$2"
  echo ""
  echo "Test: ${name}..."
  if eval "$cmd"; then
    echo "✓ ${name} PASSED"
    return 0
  else
    echo "✗ ${name} FAILED"
    return 1
  fi
}

FAILED=0

# Test 1: Liveness probe
run_test "Liveness probe" \
  "curl -f -s '${SERVICE_URL}/health/live' > /dev/null" || ((FAILED++))

# Test 2: Readiness probe (checks Redis)
run_test "Readiness probe" \
  "curl -f -s '${SERVICE_URL}/health/ready' > /dev/null" || ((FAILED++))

# Test 3: Metrics endpoint
run_test "Prometheus metrics" \
  "curl -f -s '${SERVICE_URL}/metrics' | grep -q 'rust_'" || ((FAILED++))

# Test 4: Hello API endpoint
run_test "Hello API endpoint" \
  "curl -f -s '${SERVICE_URL}/api/v1/hello' | jq -e '.message' > /dev/null" || ((FAILED++))

# Test 5: Swagger UI
run_test "Swagger UI accessible" \
  "curl -f -s '${SERVICE_URL}/swagger-ui/' > /dev/null" || ((FAILED++))

# Test 6: CloudEvent (simple JSON body)
run_test "CloudEvent with simple data" \
  "curl -f -s -X POST '${SERVICE_URL}/' \
    -H 'Content-Type: application/json' \
    -H 'Ce-Specversion: 1.0' \
    -H 'Ce-Type: dev.knative.test.simple' \
    -H 'Ce-Source: e2e-tests' \
    -H 'Ce-Id: test-001' \
    -d @tests/e2e/fixtures/cloudevents/simple-event.json > /dev/null" || ((FAILED++))

# Test 7: CloudEvent (with nested data)
run_test "CloudEvent with complex data" \
  "curl -f -s -X POST '${SERVICE_URL}/' \
    -H 'Content-Type: application/json' \
    -H 'Ce-Specversion: 1.0' \
    -H 'Ce-Type: dev.knative.test.data' \
    -H 'Ce-Source: e2e-tests' \
    -H 'Ce-Id: test-002' \
    -d @tests/e2e/fixtures/cloudevents/data-event.json > /dev/null" || ((FAILED++))

# Test 8: S3 storage example endpoint (conditional)
if [ "$INCLUDE_S3" = "true" ]; then
  echo ""
  echo "Test: S3 storage example endpoint..."
  RESPONSE=$(curl -f -s -X POST "${SERVICE_URL}/api/v1/storage/example")
  
  # Verify response structure
  echo "$RESPONSE" | jq -e '.success == true' > /dev/null || {
    echo "✗ S3 storage example FAILED (success != true)"
    echo "Response: $RESPONSE"
    ((FAILED++))
  }
  
  echo "$RESPONSE" | jq -e '.read_verified == true' > /dev/null || {
    echo "✗ S3 storage example FAILED (read_verified != true)"
    echo "Response: $RESPONSE"
    ((FAILED++))
  }
  
  echo "$RESPONSE" | jq -e '.write_size > 0' > /dev/null || {
    echo "✗ S3 storage example FAILED (write_size == 0)"
    echo "Response: $RESPONSE"
    ((FAILED++))
  }
  
  if [ $FAILED -eq 0 ]; then
    echo "✓ S3 storage example PASSED"
    echo "  Write key: $(echo "$RESPONSE" | jq -r '.write_key')"
    echo "  Write size: $(echo "$RESPONSE" | jq -r '.write_size') bytes"
  fi
else
  echo ""
  echo "Skipping S3 tests (not enabled for this scenario)"
fi

# Test 9: Check pod logs for errors
echo ""
echo "Test: Checking pod logs for errors..."
LOGS=$(kubectl logs -n test-app -l serving.knative.dev/service=rust-service --tail=100 2>/dev/null || echo "")
if echo "$LOGS" | grep -qi "panic"; then
  echo "✗ Found PANIC in logs"
  echo "$LOGS" | grep -i "panic"
  ((FAILED++))
else
  echo "✓ No panics in logs"
fi

# Summary
echo ""
echo "======================================"
if [ $FAILED -eq 0 ]; then
  echo "✓ All tests PASSED for scenario: ${SCENARIO}"
  echo "======================================"
  exit 0
else
  echo "✗ ${FAILED} test(s) FAILED for scenario: ${SCENARIO}"
  echo "======================================"
  
  echo ""
  echo "Debug information:"
  echo "Pod status:"
  kubectl get pods -n test-app
  echo ""
  echo "Recent logs:"
  kubectl logs -n test-app -l serving.knative.dev/service=rust-service --tail=50 || true
  
  exit 1
fi
