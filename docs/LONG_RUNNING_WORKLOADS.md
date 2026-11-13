# Long-Running Deployment Workload

This project was generated with `workload_type = "Deployment"`. Instead of a
Knative Service, the chart renders a standard Kubernetes workload that keeps
connections open for as long as the client needs them:

- `apps/v1 Deployment` with fixed replicas and a rolling update strategy
- core `v1 Service` (ClusterIP by default)
- optional `policy/v1 PodDisruptionBudget`
- optional `networking.k8s.io/v1 Ingress`

There is no scale-to-zero and no Knative 300-second request timeout, so this is
the right mode for WebSockets, Server-Sent Events (SSE), streaming gateways, and
other long-lived connections.

## When to use this mode

Use `Deployment` when the application must:

- keep a client connection open for minutes or hours (SSE, WebSockets);
- avoid cold starts and scale-to-zero;
- control replica count and rolling updates directly;
- drain in-flight connections during a rollout.

Keep the default `Knative` mode when you want scale-to-zero, revision-based
traffic splitting, and Knative eventing integration.

## Generated resources

The HelmRelease values in `deploy/base/helmrelease.yaml` look like this:

```yaml
services:
  app:
    workload:
      type: Deployment
      replicas: 2
      strategy:
        maxUnavailable: "0"
        maxSurge: "1"
      terminationGracePeriodSeconds: 300
      preStopSleepSeconds: 10
    service:
      type: ClusterIP
      port: 80
      sessionAffinity: None
    podDisruptionBudget:
      enabled: true
      minAvailable: "1"
```

Per-environment replicas are patched by the overlays: dev and staging default to
2, prod defaults to 3. If you answered the Knative scaling prompts, their
min/max/target values are ignored in Deployment mode (CPU and memory sizing
still applies); use `workload_replicas_*` for replica counts.

### Rolling updates and connection draining

- `strategy.maxUnavailable: 0` and `maxSurge: 1` start a new pod before removing
  an old one.
- `preStopSleepSeconds` delays SIGTERM so the Service endpoints can be updated
  first. It requires `/bin/sh` and `sleep` in the image; set it to `0` for
  distroless images.
- `terminationGracePeriodSeconds` bounds how long in-flight connections may
  survive a rollout. It must be greater than `preStopSleepSeconds`.
- The application handles SIGTERM gracefully, but long-lived streams cannot
  finish on their own. Clients must reconnect when the connection closes.

### PodDisruptionBudget

`podDisruptionBudget.enabled` defaults to `true` with `minAvailable: "1"`. With
two or more replicas, a voluntary node drain can evict at most one pod. If you
set `replicas: 1`, set `minAvailable: "0"` and `maxUnavailable: "1"` (or disable
the PDB) so node drains are not blocked.

### Sticky sessions

Set `workload_session_affinity = "ClientIP"` if WebSocket sessions keep state in
the pod. The chart renders a 10800-second client-IP affinity timeout. For
stateless SSE, leave it as `None`.

## Exposing the service

The Service is `ClusterIP` by default. Choose one:

1. **Ingress** (recommended for HTTP(S)): set `ingress_enabled = true` during
   generation, or add the values block below to the HelmRelease.
2. **LoadBalancer**: set `workload_service_type = "LoadBalancer"`.
3. **NodePort**: set `workload_service_type = "NodePort"` for local clusters.

Generated Ingress values:

```yaml
ingress:
  enabled: true
  className: "nginx"          # empty = cluster default
  annotations: {}             # pass-through map
  servicePort: 80
  hosts:
    - host: "app.example.com" # empty = hostless catch-all rule
      paths:
        - path: "/"
          pathType: Prefix
  tls:
    - hosts:
        - "app.example.com"
      secretName: "app-tls"   # empty = controller-managed certificate
```

`deploy/chart/templates/ingress.yaml` renders every key in
`ingress.annotations` verbatim, so controller-specific settings work without
template changes. For nginx and long-lived connections:

```yaml
ingress:
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-buffering: "off"
    cert-manager.io/cluster-issuer: letsencrypt-prod
```

The Ingress backend points at the chart-created Service and
`ingress.servicePort` (normally 80).

> Ingress support targets a Deployment workload. If you switch back to Knative,
> remove the `ingress` values: Knative manages its own routing through Kourier
> or your configured ingress, and there is no core Service with that name.

## SSE example endpoint

The generated application includes:

```text
GET /api/v1/stream
```

It returns `text/event-stream` and emits an immediate heartbeat, then one every
15 seconds:

```text
event: heartbeat
data: {"seq":1,"uptime_seconds":0,"service":"{{ project_name | replace: "_", "-" }}"}
```

Test it locally:

```bash
make local-up
make dev-forward
curl -N http://localhost:8080/api/v1/stream
```

On a cluster:

```bash
kubectl port-forward svc/{{ project_name | replace: "_", "-" }} 8080:{{ workload_service_port }}
curl -N http://localhost:8080/api/v1/stream
```

Metrics exposed on `/metrics`:

- `stream_connections_total`
- `stream_connections_active`
- `stream_heartbeats_sent_total`

The endpoint is a starting point. Replace the heartbeat with your own event
source (database tail, message bus, file watcher) while keeping the SSE framing.

## Unsupported Knative features

The chart rejects or cannot target a plain Deployment with:

| Feature | Why |
|---|---|
| Flagger canary | Flagger's Knative provider targets a Knative Service |
| KafkaSource / Trigger | A core Service is not a Knative-addressable sink |
| PingSource | Same: no Knative addressable |
| DomainMapping / `custom_domain` | Knative Serving routing only |
| Scale-to-zero | Replica count is fixed |

Kafka **publishing** (`feature_kafka`) is still supported: it is an outbound
connection from the app and does not need a Knative sink.

If you need event consumption, run a separate Knative service for the event
handlers and keep this Deployment for the long-lived HTTP surface.

## Local development

`make local-up` skips the Knative Serving install for this workload. The
application is reachable through `make dev-forward` at
`http://localhost:8080`.

```bash
make local-up
make dev-forward
make dev-logs
make dev-status
```

`make dev-status` shows `deploy,svc,pdb,pods` for the application. `make
dev-get-url` prints the local URL.

## Troubleshooting

```bash
kubectl get deployment,service,pdb,pod -n {{ target_namespace }}
kubectl rollout status deployment/{{ project_name | replace: "_", "-" }} -n {{ target_namespace }}
kubectl describe ingress {{ project_name | replace: "_", "-" }} -n {{ target_namespace }}
kubectl logs -l app.kubernetes.io/name={{ project_name | replace: "_", "-" }} -n {{ target_namespace }} --tail=100
```

- **Rollout stuck**: check readiness probes and `kubectl describe pod`.
- **Ingress 404/502**: verify `ingress.className`, the Ingress controller
  health, and that the backend Service port matches `ingress.servicePort`.
- **Connection drops at a fixed interval**: raise the ingress/proxy idle
  timeout via `ingress.annotations` or the load balancer's idle timeout.
- **Drain takes too long**: lower `terminationGracePeriodSeconds`, or close
  streams on a server-side shutdown signal.
