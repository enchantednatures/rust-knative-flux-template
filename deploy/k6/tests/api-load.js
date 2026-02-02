/**
 * API Load Test Script
 * 
 * This script performs load testing against the application's API endpoints.
 * It uses ramping VUs to simulate realistic traffic patterns and validates
 * that the service can handle sustained load.
 * 
 * Scenarios:
 *   - load: Ramp up to 50-100 VUs, sustain, ramp down
 * 
 * Usage:
 *   k6 run --env BASE_URL=http://localhost:8080 api-load.js
 *   
 * Environment Variables:
 *   - BASE_URL: Target service URL (required)
 *   - TEST_ID: Unique test identifier for Prometheus labels
 *   - ENVIRONMENT: Environment name (dev, staging, prod)
 *   - MAX_VUS: Maximum virtual users (default: 100)
 *   - DURATION_MINUTES: Test duration in minutes (default: 5)
 * 
 * @see https://k6.io/docs/
 */

import http from 'k6/http';
import { check, group, sleep } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';

// =============================================================================
// Custom Metrics
// =============================================================================
const errorRate = new Rate('errors');
const apiLatency = new Trend('api_latency', true);
const requestCount = new Counter('request_count');

// =============================================================================
// Dynamic Configuration
// =============================================================================
const maxVUs = parseInt(__ENV.MAX_VUS || '100');
const durationMinutes = parseInt(__ENV.DURATION_MINUTES || '5');

// Calculate stage durations
const rampUpDuration = `${Math.floor(durationMinutes * 0.2)}m`;   // 20% ramp up
const sustainDuration = `${Math.floor(durationMinutes * 0.6)}m`; // 60% sustain
const rampDownDuration = `${Math.floor(durationMinutes * 0.2)}m`; // 20% ramp down

// =============================================================================
// Test Configuration
// =============================================================================
export const options = {
  scenarios: {
    // Load test: ramp up, sustain, ramp down
    load: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: rampUpDuration || '1m', target: Math.floor(maxVUs * 0.5) },  // Ramp to 50%
        { duration: '30s', target: maxVUs },                                      // Ramp to 100%
        { duration: sustainDuration || '3m', target: maxVUs },                   // Sustain
        { duration: rampDownDuration || '1m', target: 0 },                       // Ramp down
      ],
      tags: { test_type: 'load' },
    },
  },
  
  // Pass/fail thresholds
  thresholds: {
    // API latency thresholds
    http_req_duration: [
      'p(95)<500',   // 95th percentile under 500ms
      'p(99)<1000',  // 99th percentile under 1000ms
    ],
    // Error rate thresholds
    http_req_failed: ['rate<0.01'],  // Less than 1% failures
    errors: ['rate<0.01'],
    // Custom metric thresholds
    api_latency: ['p(95)<400', 'p(99)<800'],
  },
  
  // Tags for Prometheus/Grafana filtering
  tags: {
    testid: `${__ENV.TEST_ID || 'api-load-' + Date.now()}`,
    environment: `${__ENV.ENVIRONMENT || 'dev'}`,
    test_name: 'api-load',
  },
};

// =============================================================================
// Setup Function
// =============================================================================
export function setup() {
  const baseUrl = __ENV.BASE_URL || 'http://localhost:8080';
  
  console.log(`API Load Test Configuration:`);
  console.log(`  Target: ${baseUrl}`);
  console.log(`  Max VUs: ${maxVUs}`);
  console.log(`  Duration: ~${durationMinutes} minutes`);
  
  // Validate target is reachable
  const res = http.get(`${baseUrl}/health/ready`, {
    timeout: '10s',
  });
  
  if (res.status !== 200) {
    throw new Error(`Target not ready: ${baseUrl}/health/ready returned ${res.status}`);
  }
  
  console.log('Target is ready. Starting load test...');
  
  return {
    baseUrl: baseUrl,
    apiToken: __ENV.API_TOKEN || '',
  };
}

// =============================================================================
// Default Function (VU Iteration)
// =============================================================================
export default function(data) {
  const headers = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };
  
  // Add authorization header if token is provided
  if (data.apiToken) {
    headers['Authorization'] = `Bearer ${data.apiToken}`;
  }
  
  // Group: Health Endpoints (baseline)
  group('Health Endpoints', () => {
    // Quick health check to ensure service is still responsive
    const liveRes = http.get(`${data.baseUrl}/health/live`, {
      tags: { endpoint: 'live' },
    });
    
    check(liveRes, {
      'liveness check passes': (r) => r.status === 200,
    });
    
    errorRate.add(liveRes.status !== 200);
    requestCount.add(1);
  });
  
  // Group: API Endpoints
  group('API Endpoints', () => {
    const start = Date.now();
    
    // GET request to a typical API endpoint
    // Customize this based on your application's actual endpoints
    const res = http.get(`${data.baseUrl}/api/v1/status`, {
      headers: headers,
      tags: { endpoint: 'api-status' },
    });
    
    // Record custom metrics
    const latency = Date.now() - start;
    apiLatency.add(latency);
    requestCount.add(1);
    
    // Validate response
    const passed = check(res, {
      'API returns success': (r) => r.status >= 200 && r.status < 300,
      'API response time < 500ms': (r) => r.timings.duration < 500,
      'response is JSON': (r) => {
        try {
          if (r.body) {
            JSON.parse(r.body);
          }
          return true;
        } catch {
          return r.status === 204; // No content is OK
        }
      },
    });
    
    errorRate.add(!passed);
  });
  
  // Think time between iterations (simulates real user behavior)
  // Random sleep between 0.5 and 2 seconds
  sleep(0.5 + Math.random() * 1.5);
}

// =============================================================================
// Teardown Function
// =============================================================================
export function teardown(data) {
  console.log(`API load test completed for ${data.baseUrl}`);
  console.log(`Total requests: See Prometheus metrics for detailed counts`);
}
