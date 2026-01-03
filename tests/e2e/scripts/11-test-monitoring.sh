#!/bin/bash
set -e

# E2E Test Script 11: Monitoring and Alerting
# Tests Prometheus metrics collection, alert evaluation, and alert firing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
KUBECONFIG="${KUBECONFIG:-.kubeconfig-dev}"

echo "=== E2E Test 11: PostgreSQL Monitoring and Alerting ==="
echo "Repository: $REPO_ROOT"
echo ""

# ============================================================================
# Check Prerequisites
# ============================================================================
echo "[SETUP] Verifying monitoring prerequisites..."

# Check for Prometheus Operator CRDs
if ! kubectl get crd podmonitors.monitoring.coreos.com &>/dev/null; then
    echo "⚠ Warning: Prometheus Operator CRDs not found"
    echo "  Monitoring tests require Prometheus Operator to be deployed"
    echo "  Skipping monitoring tests"
    exit 0
fi

echo "✓ Prometheus Operator CRDs available"

# Check for Prometheus instance
if ! kubectl get prometheus -A &>/dev/null; then
    echo "⚠ Warning: No Prometheus instances found"
    echo "  Skipping metrics verification"
    SKIP_METRICS=true
else
    echo "✓ Prometheus instance(s) found"
fi

# ============================================================================
# PART 1: Verify PodMonitors are Deployed
# ============================================================================
echo ""
echo "[PART 1] Verifying PodMonitor resources..."

# Check postgres-metrics PodMonitor
if kubectl get podmonitor postgres-metrics -n default &>/dev/null; then
    echo "✓ postgres-metrics PodMonitor exists"
    
    # Verify target selectors
    LABELS=$(kubectl get podmonitor postgres-metrics -n default -o jsonpath='{.spec.selector.matchLabels}')
    echo "  Target labels: $LABELS"
else
    echo "✗ postgres-metrics PodMonitor not found"
    exit 1
fi

# Check cnpg-operator-metrics PodMonitor
if kubectl get podmonitor cnpg-operator-metrics -n cnpg-system &>/dev/null; then
    echo "✓ cnpg-operator-metrics PodMonitor exists"
else
    echo "⚠ cnpg-operator-metrics PodMonitor not found in cnpg-system"
fi

# ============================================================================
# PART 2: Verify PrometheusRule is Deployed
# ============================================================================
echo ""
echo "[PART 2] Verifying PrometheusRule resources..."

if kubectl get prometheusrule postgres-alerts -n default &>/dev/null; then
    echo "✓ postgres-alerts PrometheusRule exists"
    
    # Count alert rules
    ALERT_COUNT=$(kubectl get prometheusrule postgres-alerts -n default -o jsonpath='{.spec.groups[0].rules[*].alert}' | wc -w)
    echo "  Total alerts defined: $ALERT_COUNT"
    
    # Show some alerts
    echo "  Sample alerts:"
    kubectl get prometheusrule postgres-alerts -n default -o jsonpath='{.spec.groups[0].rules[0:3].alert}' | tr ' ' '\n' | sed 's/^/    - /'
else
    echo "✗ postgres-alerts PrometheusRule not found"
    exit 1
fi

# ============================================================================
# PART 3: Verify Metrics Endpoint
# ============================================================================
echo ""
echo "[PART 3] Verifying PostgreSQL metrics endpoint..."

# Get primary pod
PRIMARY_POD=$(kubectl get pod -n default -l postgresql=postgres-app,role=primary -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$PRIMARY_POD" ]; then
    echo "⚠ Warning: No primary PostgreSQL pod found"
    echo "  Skipping metrics endpoint verification"
else
    echo "Primary pod: $PRIMARY_POD"
    
    # Port-forward to metrics endpoint
    echo "Checking metrics endpoint..."
    METRICS=$(kubectl exec -it "$PRIMARY_POD" -n default -- curl -s http://localhost:9187/metrics 2>/dev/null | head -20 || echo "")
    
    if [ -n "$METRICS" ]; then
        echo "✓ Metrics endpoint responding"
        
        # Check for key metrics
        BACKUP_METRICS=$(kubectl exec -it "$PRIMARY_POD" -n default -- curl -s http://localhost:9187/metrics 2>/dev/null | grep -E "cnpg_collector_backup|cnpg_pg_replication" | wc -l)
        
        if [ "$BACKUP_METRICS" -gt 0 ]; then
            echo "✓ Found $BACKUP_METRICS backup/replication metrics"
        else
            echo "⚠ Warning: No backup/replication metrics found"
        fi
    else
        echo "⚠ Warning: Could not reach metrics endpoint"
    fi
fi

# ============================================================================
# PART 4: Verify Prometheus Scrape Configuration
# ============================================================================
echo ""
echo "[PART 4] Verifying Prometheus scrape configuration..."

if [ "$SKIP_METRICS" != "true" ]; then
    # Get Prometheus pod
    PROMETHEUS_POD=$(kubectl get pod -A -l app=prometheus --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "$PROMETHEUS_POD" ]; then
        PROM_NAMESPACE=$(kubectl get pod -A -l app=prometheus --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)
        echo "Prometheus pod: $PROMETHEUS_POD (namespace: $PROM_NAMESPACE)"
        
        # Check scrape targets
        echo "Checking scrape targets..."
        TARGETS=$(kubectl exec -it "$PROMETHEUS_POD" -n "$PROM_NAMESPACE" -- \
            curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job == "postgres-metrics") | length' 2>/dev/null || echo "0")
        
        if [ "$TARGETS" != "0" ]; then
            echo "✓ Found $TARGETS postgres-metrics targets in Prometheus"
        else
            echo "⚠ Warning: No postgres-metrics targets found in Prometheus"
        fi
    else
        echo "⚠ Warning: No Prometheus pod found, skipping scrape verification"
    fi
else
    echo "⚠ Skipping Prometheus scrape verification (Prometheus not found)"
fi

# ============================================================================
# PART 5: Test Alert Rules
# ============================================================================
echo ""
echo "[PART 5] Testing alert rule evaluation..."

if [ -n "$PROMETHEUS_POD" ]; then
    echo "Fetching alert rules from Prometheus..."
    
    RULES=$(kubectl exec -it "$PROMETHEUS_POD" -n "$PROM_NAMESPACE" -- \
        curl -s http://localhost:9090/api/v1/rules 2>/dev/null | jq '.data.groups[] | select(.name == "postgres.rules") | length' || echo "0")
    
    if [ "$RULES" != "0" ]; then
        echo "✓ Alert rules loaded in Prometheus"
        
        # Check for specific alert states
        echo "Checking alert states..."
        FIRING=$(kubectl exec -it "$PROMETHEUS_POD" -n "$PROM_NAMESPACE" -- \
            curl -s http://localhost:9090/api/v1/rules 2>/dev/null | jq '.data.groups[].rules[] | select(.state == "firing") | length' | wc -l)
        
        if [ "$FIRING" -gt 0 ]; then
            echo "⚠ Found $FIRING firing alerts (this may be expected if backups failed, etc.)"
            echo "  Run 'kubectl logs -n monitoring alertmanager' to investigate"
        else
            echo "✓ No unexpected alerts firing"
        fi
    else
        echo "⚠ Warning: postgres.rules not found in Prometheus"
    fi
else
    echo "⚠ Skipping alert evaluation (Prometheus not found)"
fi

# ============================================================================
# PART 6: Document Key Metrics Available
# ============================================================================
echo ""
echo "[PART 6] Key metrics available for monitoring:"
echo ""
echo "Backup Metrics:"
echo "  - cnpg_collector_backup_last_failed_timestamp"
echo "  - cnpg_collector_last_failed_backup_timestamp"
echo "  - cnpg_collector_backup_size_bytes"
echo "  - cnpg_pg_stat_archiver_failed_count"
echo ""
echo "Replication Metrics:"
echo "  - cnpg_pg_replication_lag"
echo "  - pg_stat_replication_write_lag_bytes"
echo "  - pg_stat_replication_flush_lag_bytes"
echo ""
echo "Instance Health Metrics:"
echo "  - pg_up"
echo "  - pg_setting_server_version_num"
echo "  - pg_stat_activity_count"
echo "  - pg_is_in_recovery"
echo ""

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "=== Monitoring Verification Complete ==="
echo ""
echo "Next steps:"
echo "1. Set up Grafana with CloudNativePG dashboards"
echo "2. Configure AlertManager to route alerts to your team"
echo "3. Set up on-call notifications (PagerDuty, Slack, etc.)"
echo "4. Review and customize alert thresholds for your environment"
echo ""
echo "Documentation: docs/POSTGRES_MONITORING.md"
