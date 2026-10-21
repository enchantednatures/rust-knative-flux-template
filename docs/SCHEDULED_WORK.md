# Scheduled Work with Knative PingSource

This guide explains the scheduled-work option in this template. When you answer
`yes` to the `feature_cron` prompt, the generated project gets a Knative
PingSource that sends a fixed CloudEvent to the application on a cron schedule.

The PingSource is an event source, not a job runner. Each tick is an HTTP
delivery to the Knative Service. The application decides what the tick means.

## What the template generates

The `feature_cron` flag adds three prompts:

| Prompt | Meaning | Template default |
|--------|---------|------------------|
| `cron_schedule` | Cron expression for the tick | `0 * * * *` (hourly, on the hour) |
| `cron_timezone` | IANA time zone for the schedule | `UTC` |
| `cron_payload` | JSON text sent as the event body | `{"message":"scheduled tick"}` |

The generated HelmRelease carries the values under `spec.values`:

```yaml
pingsources:
  scheduled:
    schedule: "{{ cron_schedule }}"
    timezone: "{{ cron_timezone }}"
    contentType: application/json
    data: |
      {{ cron_payload }}
    sink: "app"
```

The `sink: "app"` value is a root sink reference to the `services.app` Knative
Service. The chart resolves it to that service, and the event is delivered to
the service root path `/`. There is no target-path setting and no custom event
type setting.

The generated project also includes `scripts/dev/install-knative-eventing.sh`,
which installs Knative Eventing core plus the PingSource CRD for local
development. It does not install Kafka controllers or Kafka sources.

## Event contract

A PingSource emits a CloudEvent with these properties:

| Property | Value |
|----------|-------|
| Type | `dev.knative.sources.ping` |
| Source | `/apis/v1/namespaces/<namespace>/pingsources/<pingsource-name>` |
| Content type | `application/json`, from `contentType` |
| Body | The fixed `data` value from the HelmRelease |
| ID | A new event ID for each tick |

The type is fixed by Knative. It is not configurable through this template, and
the chart does not set `ceOverrides`. The handler in `src/handlers/events.rs`
routes on the constant `dev.knative.sources.ping`, so a scheduled event is
handled by `handle_scheduled_event` and returns:

```json
{"received": true, "event_id": "<event-id>"}
```

Other event types continue to use the normal ping handler and respond with a
`pong` reply.

Keep the payload valid JSON. The chart sets `contentType: application/json`,
and the event is delivered with that content type. The payload is fixed in the
PingSource, so every tick sends the same body.

## PingSource semantics and limits

PingSource is deliberately simple. Plan around these limits:

- **Fixed payload.** The same `data` is sent on every tick. Changing the body
  means changing the HelmRelease value (or regenerating the project) and
  letting Flux reconcile the change.
- **No delivery spec.** PingSource does not expose the Eventing `delivery`
  fields for retries, backoff, or a dead letter sink. There is no DLQ for
  scheduled ticks in this template.
- **No retry on failed delivery.** If the HTTP delivery to the service fails,
  the source does not retry that tick. The tick is lost. Do not treat a
  scheduled event as a durable queue record.
- **No replay of missed schedules.** If the adapter is not running, or the
  cluster is unavailable when a tick is due, that tick is not replayed when the
  adapter returns. The next matching time is the next tick.
- **Shared adapter.** PingSources are handled by the cluster-wide
  `pingsource-mt-adapter` deployment in `knative-eventing`. The adapter can
  scale to zero when there is no PingSource activity. The first tick after a
  cold adapter may be delayed while the adapter starts.
- **Cold start on the consumer.** The Knative Service can also be at zero
  replicas. A tick then includes the service cold-start time. Keep startup fast
  and keep the readiness probe meaningful.
- **No exactly-once guarantee.** Because delivery is not retried, a single tick
  is usually delivered once, but you should not build correctness around
  exactly-once behavior. A proxy, a manual resend, or a duplicate delivery can
  still produce repeated work.

### Idempotency

The same payload arrives on every tick, so the payload cannot tell you which
run it belongs to. Use the CloudEvent `id` for logging and deduplication when a
tick triggers a side effect that must happen at most once.

The example handler logs the event ID and payload and acknowledges the event.
It does not deduplicate. In production, make scheduled handlers idempotent:

- Use a natural key and an upsert instead of an unconditional insert.
- Record processed event IDs with a TTL if a side effect must run once.
- Make external calls safe to repeat, or guard them with a transaction or
  idempotency key.
- Treat a missed tick as possible. Add a catch-up path, such as a periodic
  reconciliation query, when the work must not be skipped.

## PingSource compared with CronJob and KEDA

These tools solve different problems. Pick the one that matches the work.

| Option | What it does | Retries | Fit for this template |
|--------|--------------|---------|----------------------|
| Knative PingSource | Emits a CloudEvent to an HTTP sink on a cron schedule | None; no delivery or DLQ spec | Best when the work is an HTTP or CloudEvent handler on the Knative Service |
| Kubernetes CronJob | Creates a Job, and the Job creates Pods that run to completion | `backoffLimit` and Job restart policy | Best for batch jobs that must run to completion, not for triggering a service |
| KEDA cron scaler | Changes a workload's replica count during time windows | Not applicable; it does not invoke anything | Best for pre-scaling a workload for known busy periods |

A Kubernetes CronJob is a job runner. It runs a container image as a Job and
records Job history. It does not deliver a CloudEvent to a Knative Service and
does not replace PingSource for this template's scheduled handler.

The KEDA cron scaler only scales a workload. It does not send an event and does
not start a job. The workload still needs its own trigger or loop to do work
while it is scaled up.

Use PingSource when the schedule should invoke the application's event handler.
Use a CronJob when the work is a self-contained batch process that exits when
finished. Use KEDA cron scaling when the workload already has a trigger and you
only need capacity ahead of a predictable peak.

## CronJobSource is removed

Knative Eventing v0.14 removed the legacy sources, including
`CronJobSource` (`sources.eventing.knative.dev`). The v0.14.2 release notes list
`CronJobSource/sources.eventing.knative.dev` under removed resources, and commit
`4d1c20b9c3a9c0d4987cba8ce8db4f6547bf631d` ("Remove Legacy Client from
Eventing") removed the legacy source client. A modern Knative Eventing install
does not serve that API, so a `CronJobSource` manifest will not reconcile.

PingSource is the supported successor for cron-triggered CloudEvents on Knative
Eventing. Do not add a `CronJobSource` CRD, manifest, or example to a generated
project.

References:

- [Knative Eventing v0.14.2 release notes](https://github.com/knative/eventing/releases/tag/v0.14.2)
- [Remove Legacy Client from Eventing (commit 4d1c20b)](https://github.com/knative/eventing/commit/4d1c20b9c3a9c0d4987cba8ce8db4f6547bf631d)
- [PingSource reference](https://knative.dev/docs/eventing/sources/ping-source/reference/)

## Configuration and rollout

The schedule, time zone, and payload live in
`deploy/base/helmrelease.yaml` under `spec.values.pingsources.scheduled`:

```yaml
pingsources:
  scheduled:
    schedule: "0 * * * *"       # hourly at minute 0
    timezone: "UTC"
    contentType: application/json
    data: |
      {"message":"scheduled tick"}
    sink: "app"
```

To change the schedule or payload, edit the HelmRelease value, commit it, and
let Flux reconcile. In local development you can also apply the rendered
overlay directly. Keep the sink as `"app"`; the chart validates that the sink
references a `services` key, and the app is the only service in the default
values.

The event type and target path are not settings. Do not add a `ceOverrides`
entry to change the type, and do not append a path to the sink. The handler in
`src/handlers/events.rs` is wired for the fixed type.

### Schedule syntax

Use a standard five-field cron expression (`minute hour day-of-month month
day-of-week`). Quartz-style expressions with a seconds field are also supported
by PingSource, but the template default uses the standard five-field form.

Examples:

| Expression | Meaning |
|------------|---------|
| `0 * * * *` | Every hour, on the hour |
| `*/15 * * * *` | Every 15 minutes |
| `0 2 * * *` | Daily at 02:00 in the configured time zone |
| `0 9 * * 1-5` | Weekdays at 09:00 in the configured time zone |

Set `cron_timezone` to an IANA time zone such as `UTC`, `America/New_York`, or
`Europe/Berlin`. The default is `UTC` to avoid daylight-saving surprises.

## Operations

### Inspect the PingSource

```bash
# List PingSources in the target namespace
kubectl get pingsources.sources.knative.dev -n <namespace>

# Describe the generated source (name comes from the pingsources key)
kubectl describe pingsources.sources.knative.dev <pingsource-name> -n <namespace>

# Full spec and status, including the resolved sink URI
kubectl get pingsources.sources.knative.dev <pingsource-name> -n <namespace> -o yaml
```

In the status, check the `Ready` condition and `sinkUri`. A `Ready=True` source
with a `sinkUri` that points at the Knative Service is the normal state.

### Application logs

```bash
kubectl logs -n <namespace> \
  -l serving.knative.dev/service=<service-name> \
  -c user-container --tail=100
```

Successful scheduled deliveries appear as `Received scheduled CloudEvent` with
the event ID, type, source, and payload.

### PingSource adapter logs

PingSources are reconciled and dispatched by the shared adapter:

```bash
kubectl -n knative-eventing get pods -l app=pingsource-mt-adapter
kubectl -n knative-eventing logs deployment/pingsource-mt-adapter --tail=100
```

If the adapter has no pods, that is expected when no PingSource is active.
Creating the PingSource wakes it.

### Send a local test event

With `make dev-forward` running, send the same fixed type and payload to the
service root:

```bash
curl -i -X POST http://localhost:8080/ \
  -H "ce-specversion: 1.0" \
  -H "ce-type: dev.knative.sources.ping" \
  -H "ce-source: /apis/v1/namespaces/default/pingsources/scheduled" \
  -H "ce-id: local-scheduled-1" \
  -H "Content-Type: application/json" \
  -d '{"message":"scheduled tick"}'
```

Expected response:

```json
{"received":true,"event_id":"local-scheduled-1"}
```

This exercises the same handler path as a real tick. It does not test the
adapter or the schedule.

### Common checks

| Symptom | Check |
|---------|-------|
| No scheduled events | `kubectl get pingsources` shows `Ready=True` and a valid `sinkUri` |
| Events stopped after a cluster change | Check the `pingsource-mt-adapter` pods and the Eventing controller logs |
| First tick is slow | Check Knative Service cold start and `minScale` |
| Duplicate side effects | Make the handler idempotent and deduplicate on the event ID |
| Payload rejected or malformed | Confirm `cron_payload` is valid JSON and `contentType` is `application/json` |

## Security and compliance

- **The payload is configuration, not a secret store.** `cron_payload` is
  written into `deploy/base/helmrelease.yaml`, which is committed to Git and
  visible in the HelmRelease values in the cluster. Never put passwords, API
  tokens, private keys, or personal data in the payload. If scheduled work needs
  a credential, read it at runtime from a Kubernetes Secret or an external
  secret manager.
- **Payloads are logged.** The example handler logs the full event data. Treat
  the payload as non-sensitive operational metadata.
- **Eventing installation is local-dev only.** The
  `scripts/dev/install-knative-eventing.sh` script installs cluster-scoped
  Eventing CRDs, controllers, and webhooks and requires cluster-admin. It is
  intended for a disposable local Kind cluster. Do not run it against a shared
  or production cluster. Production clusters should use a supported Eventing
  install method and a reviewed upgrade process.
- **Review the Eventing footprint.** Eventing adds controllers, webhooks, and
  RBAC to the cluster. Keep the installed version patched, restrict who can
  create sources and brokers, and apply network policies where your platform
  requires them.
- **Least privilege for the application.** The application does not need
  Kubernetes API permissions to receive a PingSource event. It only needs to
  serve HTTP on port 8080.

## References

- [PingSource reference](https://knative.dev/docs/eventing/sources/ping-source/reference/)
- [Creating a PingSource object](https://knative.dev/docs/eventing/sources/ping-source/)
- [Knative Eventing sinks](https://knative.dev/docs/eventing/sinks/)
- [Knative Eventing v0.14.2 release notes](https://github.com/knative/eventing/releases/tag/v0.14.2)
- [Remove Legacy Client from Eventing (commit 4d1c20b)](https://github.com/knative/eventing/commit/4d1c20b9c3a9c0d4987cba8ce8db4f6547bf631d)
- [KEDA cron scaler](https://keda.sh/docs/2.21/scalers/cron/)
- [Kubernetes CronJob](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/)
