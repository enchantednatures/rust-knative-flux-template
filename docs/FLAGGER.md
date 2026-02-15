# Flagger Canary Release Promotion

This project uses [Flagger](https://flagger.app) for automated canary release promotion
with Knative Serving. When a new image is deployed, Flagger gradually shifts traffic to
the new revision while evaluating metric gates and running k6 load tests. If any gate
fails, the rollout is automatically rolled back.

## How It Works

```
New image pushed
  → Flux ImageUpdateAutomation updates knative-service.yaml
  → Flux reconciles → Knative creates new revision
  → Flagger detects new revision → starts canary analysis

  Step 0 — Smoke test (pre-rollout):
    → k6 smokeTest() hits /health/live on the canary revision
    → Non-zero exit? → Abort immediately, no traffic shifted

  Step 1..N — Load test + metric gates (rollout, every 1 minute):
    → k6 default() sends {{ k6_vus }} VUs to the canary revision
    → k6 thresholds checked: p95 < 500ms, error rate < 1%
    → Prometheus gates checked: success rate ≥ {{ canary_success_rate_threshold }}%,
      p99 latency ≤ {{ canary_latency_threshold_ms }}ms
    → All pass? → Advance traffic by 10% (10% → 20% → ... → 50%)
    → Any fail 5× in a row? → Rollback to previous revision

  Final step — Promotion:
    → Traffic at 50% with no failures → shift 100% to new revision
    → Retire the previous primary revision
```

No service mesh is required. Flagger uses Knative's native
`spec.traffic` revision-based traffic splitting.

## k6 Load Testing

The canary analysis uses [k6](https://k6.io) for synthetic load testing via
the `flagger-loadtester`. The k6 script is generated into a ConfigMap and mounted
into the loadtester pod at `/scripts/canary-test.js`.

### File locations

| File | Purpose |
|------|---------|
| `deploy/components/flagger/k6-configmap.yaml` | ConfigMap containing the k6 script |
| `deploy/components/flagger/loadtester-patch.yaml` | Patches the loadtester HelmRelease to mount the ConfigMap |
| `deploy/components/flagger/canary.yaml` | Defines the two webhook stages |

### Two-stage webhook workflow

**Stage 1 — `pre-rollout` smoke test:**
Runs before any traffic is shifted. Uses `k6 run --export-only smokeTest` to call
the `/health/live` endpoint on the new canary revision. A single failure here aborts
the entire rollout before any real users see the new version.

**Stage 2 — `rollout` load test:**
Runs on every 1-minute analysis interval. Uses `k6 run` (default export) to send
`{{ k6_vus }}` virtual users to the canary revision for 60 seconds. k6 thresholds
are evaluated; a breach causes a non-zero exit, which Flagger counts as a failed check.

### Customizing the k6 script

Edit `deploy/components/flagger/k6-configmap.yaml`. The script targets:

```
http://{{ project_name | replace: "_", "-" }}-canary.{{ target_namespace }}.svc.cluster.local/
```

The URL uses the full cluster-local FQDN because the loadtester pod runs in the
`flagger-system` namespace and makes cross-namespace requests.

To change VUs, duration, or thresholds:

```javascript
export const options = {
  vus: {{ k6_vus }},       // set via k6_vus at generation time
  duration: '1m',           // match the canary analysis interval

  thresholds: {
    'http_req_duration': ['p(95)<500'],  // adjust latency threshold
    'errors': ['rate<0.01'],             // adjust error rate
  },
};
```

## Metric Gates

Each 1-minute analysis step must pass all Prometheus metric gates:

| Gate | Threshold | Query source |
|------|-----------|-------------|
| HTTP success rate | ≥ {{ canary_success_rate_threshold }}% | `revision_request_count` success ratio |
| p99 latency | ≤ {{ canary_latency_threshold_ms }}ms | `revision_request_latencies` histogram |
| Custom app metric | ≥ 0 | Placeholder — fill in your own KPI |

Thresholds are defined in `deploy/components/flagger/canary.yaml`.
PromQL queries are defined in `deploy/components/flagger/metric-templates.yaml`.

## Installing the Flagger Operator

Flagger is a cluster-wide controller. Install it **once per cluster** using the provided
FluxCD Kustomization — not per application or namespace.

```bash
# Apply the Flagger operator Kustomization to your flux-system
kubectl apply -f deploy/flux/flagger-kustomization.yaml

# Verify the operator is running
kubectl rollout status deploy/flagger -n flagger-system
kubectl rollout status deploy/flagger-loadtester -n flagger-system
```

The operator HelmReleases are in `deploy/infrastructure/flagger/operator/`.

> **Important:** The app FluxCD Kustomization (`deploy/flux/kustomization.yaml`) has a
> `dependsOn: [{name: flagger}]` block so Flux will always install the operator before
> applying the `Canary` object. If you're installing manually, apply the operator first.

## Monitoring a Canary Rollout

```bash
# Watch canary status — shows current phase, traffic weights, and metric values
kubectl describe canary {{ project_name | replace: "_", "-" }} -n <namespace>

# Stream Flagger operator logs
kubectl logs -n flagger-system deploy/flagger -f

# Stream load tester logs (shows k6 output during analysis)
kubectl logs -n flagger-system deploy/flagger-loadtester -f

# List all canaries across namespaces
kubectl get canaries -A
```

### Canary Phase Reference

| Phase | Meaning |
|-------|---------|
| `Initialized` | Flagger has detected the service and is waiting for a new revision |
| `Progressing` | Canary analysis running; traffic shifting in steps |
| `Succeeded` | Promotion complete; canary revision is now primary |
| `Failed` | Metric gates failed `threshold` times; rolled back to primary |
| `Waiting` | Waiting for a new revision to become Ready |

## Pausing and Resuming

```bash
# Pause a canary mid-rollout (halts traffic shifting)
kubectl annotate canary/{{ project_name | replace: "_", "-" }} \
  flagger.app/canary.paused="true" -n <namespace>

# Resume a paused canary
kubectl annotate canary/{{ project_name | replace: "_", "-" }} \
  flagger.app/canary.paused- -n <namespace>
```

## Manual Rollback

Flagger rolls back automatically when metric gates or k6 thresholds fail. To force an
immediate rollback:

```bash
# Delete the Canary object — Flagger shifts 100% traffic back to primary revision
kubectl delete canary/{{ project_name | replace: "_", "-" }} -n <namespace>

# Re-apply after fixing the issue
kubectl apply -k deploy/overlays/staging  # or prod
```

## Customizing Analysis Parameters

Edit `deploy/components/flagger/canary.yaml`:

```yaml
analysis:
  interval: 1m          # how often to evaluate metrics and run k6
  threshold: 5          # consecutive failures before rollback
  maxWeight: 50         # max % traffic to canary before promotion
  stepWeight: 10        # traffic increment per step
  metrics:
    - name: request-success-rate
      thresholdRange:
        min: 99         # change this to lower the success rate requirement
    - name: request-duration
      thresholdRange:
        max: 500        # change this to adjust the p99 latency limit (ms)
```

## Adding a Custom Metric Gate

Replace the placeholder query in `deploy/components/flagger/metric-templates.yaml`:

```yaml
# Example: error rate from your app's own Prometheus counter
query: |
  sum(rate(http_requests_total{job="{{ target }}", status=~"5.."}[{{ interval }}]))
  / sum(rate(http_requests_total{job="{{ target }}"}[{{ interval }}]))
```

The variables `{{ target }}`, `{{ namespace }}`, and `{{ interval }}` are substituted
by Flagger at runtime. `{{ target }}` is the Knative service name.

To remove the custom metric gate entirely, delete the third entry from the `metrics:`
list in `canary.yaml` and delete the `custom-metric` MetricTemplate from
`metric-templates.yaml`.

## Adding Notifications

Uncomment the `notify-promotion` webhook in `canary.yaml` to trigger alerts on
promotion. Flagger supports Slack, Microsoft Teams, PagerDuty, Discord, and generic
webhooks. See the [Flagger alerting docs](https://docs.flagger.app/usage/alerting).

## Cross-Namespace Considerations

The `flagger-loadtester` runs in `flagger-system`. The k6 script targets the canary
revision using its full cluster-local FQDN:

```
<service>-canary.<target_namespace>.svc.cluster.local
```

If your staging and production overlays use different namespaces (e.g. `staging` and
`production`), you'll need to patch the k6 script or the webhook `cmd` per overlay:

```yaml
# deploy/overlays/staging/canary-patch.yaml
- op: replace
  path: /spec/analysis/webhooks/1/metadata/cmd
  value: "k6 run /scripts/canary-test.js"
  # and update the URL in k6-configmap.yaml for that namespace
```

Alternatively, update the `target_namespace` variable at generation time if you use
a single namespace across all environments.
