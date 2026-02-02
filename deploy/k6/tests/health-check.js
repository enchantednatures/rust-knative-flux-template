/**
 * Health Check Load Test Script
 * 
 * This script tests the health endpoints of the application to validate
 * basic availability and responsiveness. It's designed for smoke testing
 * and quick validation of deployments.
 * 
 * Endpoints Tested:
 *   - /health/live: Liveness probe
 *   - /health/ready: Readiness probe
 * 
 * Usage:
 *   k6 run --env BASE_URL=http://localhost:8080 health-check.js
 *   
 * Environment Variables:
 *   - BASE_URL: Target service URL (required)
 *   - TEST_ID: Unique test identifier for Prometheus labels
 *   - ENVIRONMENT: Environment name (dev, staging, prod)
 * 
 * @see https://k6.io/docs/
 */

import http from 'k6/http';
import { check, group, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// =============================================================================
// Custom Metrics
// =============================================================================
const errorRate = new Rate('errors');
const liveLatency = new Trend('live_latency', true);
const readyLatency = new Trend('ready_latency', true);

// =============================================================================
// Test Configuration
// =============================================================================
export const options = {
  scenarios: {
    // Smoke test: minimal load for quick validation
    smoke: {
      executor: 'constant-vus',
      vus: 1,
      duration: '1m',
      tags: { test_type: 'smoke' },
    },
  },
  
  // Pass/fail thresholds
  thresholds: {
    // Health endpoints should respond quickly
    http_req_duration: ['p(95)<200', 'p(99)<500'],
    // Error rate should be negligible
    http_req_failed: ['rate<0.01'],
    errors: ['rate<0.01'],
    // Custom latency thresholds
    live_latency: ['p(95)<100'],
    ready_latency: ['p(95)<150'],
  },
  
  // Tags for Prometheus/Grafana filtering
  tags: {
    testid: `${__ENV.TEST_ID || 'health-check-' + Date.now()}`,
    environment: `${__ENV.ENVIRONMENT || 'dev'}`,
    test_name: 'health-check',
  },
};

// =============================================================================
// Setup Function
// =============================================================================
export function setup() {
  const baseUrl = __ENV.BASE_URL || 'http://localhost:8080';
  
  console.log(`Health Check Test - Target: ${baseUrl}`);
  
  // Validate target is reachable
  const res = http.get(`${baseUrl}/health/live`, {
    timeout: '10s',
  });
  
  if (res.status !== 200) {
    throw new Error(`Target not reachable: ${baseUrl}/health/live returned ${res.status}`);
  }
  
  console.log('Target is reachable. Starting test...');
  
  return {
    baseUrl: baseUrl,
  };
}

// =============================================================================
// Default Function (VU Iteration)
// =============================================================================
export default function(data) {
  // Group: Liveness Check
  group('Liveness Probe', () => {
    const start = Date.now();
    
    const res = http.get(`${data.baseUrl}/health/live`, {
      tags: { endpoint: 'live' },
    });
    
    liveLatency.add(Date.now() - start);
    
    const passed = check(res, {
      'liveness returns 200': (r) => r.status === 200,
      'liveness response time < 100ms': (r) => r.timings.duration < 100,
    });
    
    errorRate.add(!passed);
  });
  
  // Group: Readiness Check
  group('Readiness Probe', () => {
    const start = Date.now();
    
    const res = http.get(`${data.baseUrl}/health/ready`, {
      tags: { endpoint: 'ready' },
    });
    
    readyLatency.add(Date.now() - start);
    
    const passed = check(res, {
      'readiness returns 200': (r) => r.status === 200,
      'readiness response time < 150ms': (r) => r.timings.duration < 150,
    });
    
    errorRate.add(!passed);
  });
  
  // Short sleep between iterations
  sleep(0.5);
}

// =============================================================================
// Teardown Function
// =============================================================================
export function teardown(data) {
  console.log(`Health check test completed for ${data.baseUrl}`);
}
