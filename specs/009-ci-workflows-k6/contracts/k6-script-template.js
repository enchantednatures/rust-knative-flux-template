/**
 * k6 Load Test Script Contract
 * 
 * This template defines the expected structure for k6 test scripts
 * used with the k6 operator in Kubernetes.
 * 
 * @see https://k6.io/docs/using-k6/
 */

import http from 'k6/http';
import { check, group, sleep } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';

// =============================================================================
// Custom Metrics (optional)
// =============================================================================
const errorRate = new Rate('errors');
const apiLatency = new Trend('api_latency');
const requestCount = new Counter('request_count');

// =============================================================================
// Test Configuration (required)
// =============================================================================
export const options = {
  // Scenarios define different load patterns
  scenarios: {
    // Smoke test: quick validation with minimal load
    smoke: {
      executor: 'constant-vus',
      vus: 1,
      duration: '1m',
      tags: { test_type: 'smoke' },
    },
    
    // Load test: ramp up, sustain, ramp down
    load: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: 50 },   // Ramp up to 50 VUs
        { duration: '5m', target: 50 },   // Stay at 50 VUs
        { duration: '2m', target: 0 },    // Ramp down
      ],
      startTime: '1m',  // Start after smoke test
      tags: { test_type: 'load' },
    },
  },
  
  // Thresholds define pass/fail criteria (required)
  thresholds: {
    // HTTP request duration thresholds
    http_req_duration: [
      'p(95)<500',   // 95th percentile under 500ms
      'p(99)<1000',  // 99th percentile under 1000ms
    ],
    
    // Error rate threshold
    http_req_failed: ['rate<0.01'],  // Less than 1% failures
    
    // Custom metric thresholds
    errors: ['rate<0.01'],
    api_latency: ['p(95)<400'],
  },
  
  // Tags for filtering in Grafana (recommended)
  tags: {
    testid: `${__ENV.TEST_ID || 'default'}`,
    environment: `${__ENV.ENVIRONMENT || 'dev'}`,
  },
};

// =============================================================================
// Setup Function (optional)
// Runs once before the test starts
// =============================================================================
export function setup() {
  const baseUrl = __ENV.BASE_URL || 'http://localhost:8080';
  
  console.log(`Test setup - Target: ${baseUrl}`);
  
  // Validate target is reachable
  const res = http.get(`${baseUrl}/health/live`);
  if (res.status !== 200) {
    throw new Error(`Target not reachable: ${res.status}`);
  }
  
  // Return data to be used in default function
  return {
    baseUrl: baseUrl,
    apiToken: __ENV.API_TOKEN || '',
  };
}

// =============================================================================
// Default Function (required)
// Runs once per VU iteration
// =============================================================================
export default function(data) {
  // Group: Health Checks
  group('Health Checks', () => {
    // Liveness probe
    const liveRes = http.get(`${data.baseUrl}/health/live`);
    check(liveRes, {
      'liveness status is 200': (r) => r.status === 200,
    });
    errorRate.add(liveRes.status !== 200);
    
    // Readiness probe
    const readyRes = http.get(`${data.baseUrl}/health/ready`);
    check(readyRes, {
      'readiness status is 200': (r) => r.status === 200,
    });
    errorRate.add(readyRes.status !== 200);
  });
  
  // Group: API Endpoints
  group('API Endpoints', () => {
    const start = Date.now();
    
    // Example: GET request
    const res = http.get(`${data.baseUrl}/api/v1/resource`, {
      headers: {
        'Content-Type': 'application/json',
        'Authorization': data.apiToken ? `Bearer ${data.apiToken}` : '',
      },
    });
    
    // Record custom metrics
    apiLatency.add(Date.now() - start);
    requestCount.add(1);
    
    // Validate response
    check(res, {
      'API returns 200': (r) => r.status === 200,
      'response has valid JSON': (r) => {
        try {
          JSON.parse(r.body);
          return true;
        } catch {
          return false;
        }
      },
    });
    
    errorRate.add(res.status !== 200);
  });
  
  // Think time between iterations (simulates real user behavior)
  sleep(1);
}

// =============================================================================
// Teardown Function (optional)
// Runs once after the test ends
// =============================================================================
export function teardown(data) {
  console.log('Test completed');
}

// =============================================================================
// Handle Summary (optional)
// Custom summary output
// =============================================================================
export function handleSummary(data) {
  return {
    'stdout': textSummary(data, { indent: '  ', enableColors: true }),
  };
}

// Simple text summary helper
function textSummary(data, options) {
  const lines = [];
  lines.push('');
  lines.push('Test Summary');
  lines.push('============');
  lines.push(`Duration: ${data.state.testRunDurationMs}ms`);
  lines.push(`VUs: ${data.metrics.vus?.values?.value || 0}`);
  lines.push(`Iterations: ${data.metrics.iterations?.values?.count || 0}`);
  lines.push('');
  
  // HTTP metrics
  if (data.metrics.http_req_duration) {
    lines.push('HTTP Request Duration:');
    lines.push(`  p(50): ${data.metrics.http_req_duration.values['p(50)']?.toFixed(2)}ms`);
    lines.push(`  p(95): ${data.metrics.http_req_duration.values['p(95)']?.toFixed(2)}ms`);
    lines.push(`  p(99): ${data.metrics.http_req_duration.values['p(99)']?.toFixed(2)}ms`);
  }
  
  // Threshold results
  lines.push('');
  lines.push('Thresholds:');
  for (const [name, threshold] of Object.entries(data.metrics)) {
    if (threshold.thresholds) {
      for (const [key, result] of Object.entries(threshold.thresholds)) {
        const status = result.ok ? '✓' : '✗';
        lines.push(`  ${status} ${name}: ${key}`);
      }
    }
  }
  
  return lines.join('\n');
}
