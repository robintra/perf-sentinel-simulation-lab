# Architecture

The S1 lab is a local k3d cluster hosting the observability stack
needed to validate perf-sentinel against Java services in S2. No
application service runs in S1, the cluster is only set up to receive
traffic.

## Flow diagram

```
                        Host (macOS)
  ┌──────────────────────────────────────────────────────────┐
  │  localhost:3000  ──┐                  localhost:14318 ──┐│
  │  (Grafana)         │                  (perf-sentinel)   ││
  └────────────────────┼─────────────────────────────────────┘
                       │ kubectl port-forward (background)
                       ▼
  ┌──────────────────────────────────────────────────────────┐
  │ k3d cluster perf-sentinel-lab (1 server + 2 agents)      │
  │                                                          │
  │  ┌──────────────────────────────────────────────────┐    │
  │  │ namespace observability                          │    │
  │  │                                                  │    │
  │  │   OTel Collector (DaemonSet)                     │    │
  │  │     receivers: OTLP gRPC 4317, HTTP 4318         │    │
  │  │     exporters:                                   │    │
  │  │       ├── otlphttp -> tempo:4318                 │    │
  │  │       ├── otlphttp -> perf-sentinel-daemon:14318 │    │
  │  │       └── prometheus :8889/metrics               │    │
  │  │                                                  │    │
  │  │   Tempo (single-binary)                          │    │
  │  │     receivers: OTLP 4317/4318, query 3200        │    │
  │  │     storage: local PVC 10Gi                      │    │
  │  │                                                  │    │
  │  │   perf-sentinel daemon                           │    │
  │  │     OTLP HTTP 14318, gRPC 14317                  │    │
  │  │     /metrics, /api/{status,findings,...}         │    │
  │  │                                                  │    │
  │  │   Prometheus + Grafana (kube-prometheus-stack)   │    │
  │  │     Prometheus scrape: ServiceMonitors           │    │
  │  │     Grafana datasources: Prometheus, Tempo       │    │
  │  └──────────────────────────────────────────────────┘    │
  │                                                          │
  │  ┌──────────────────────────────────────────────────┐    │
  │  │ namespace db                                     │    │
  │  │   PostgreSQL 18.3 (StatefulSet, PVC 5Gi)         │    │
  │  │   schemas: orders, payments, notifications       │    │
  │  └──────────────────────────────────────────────────┘    │
  │                                                          │
  │  namespace shop  (empty, reserved for S2)                │
  │  namespace ci    (empty, reserved for S3/S4)             │
  └──────────────────────────────────────────────────────────┘
```

## Components and design choices

### Tempo single-binary (direct manifest)

Tempo 2.9.0 is deployed via `manifests/tempo.yaml` in single-binary
mode (`-target=all`). No Helm chart: both official Grafana charts
(`grafana/tempo` and `grafana/tempo-distributed`) are flagged
`deprecated: true` and Grafana points to the Tempo Operator, which
does not yet have an officially maintained Helm chart. The direct
manifest sidesteps that friction and reads more clearly.

Single-binary instead of microservices (distributed) because the
distributed variant requires 5 to 9 Tempo pods plus an object store
(S3/MinIO/GCS) even for low throughput. Single-binary fits in
~600 MiB of RAM with the same OTLP ingest protocol.

Trace storage is local on PVC (`/var/tempo/blocks` and
`/var/tempo/wal`). No S3, no GCS. Retention is set to 24 h, the lab
is meant to be used in short investigation sessions rather than
continuously.

A ServiceMonitor ships with the manifest so Prometheus scrapes
`/metrics` on port 3200 (same conventional labels as the other lab
ServiceMonitors).

### kube-prometheus-stack

Pinned chart 84.1.0 (operator v0.90.1). Components disabled to reduce
memory footprint and avoid k3d failures:

- Alertmanager: not relevant in a lab.
- ThanosRuler: same.
- AdmissionWebhooks: these webhooks need cert-manager or manual
  certificates and tend to break the bootstrap.
- defaultRules: the bundled alerting rules (paired with Alertmanager)
  are useless when Alertmanager is off.

ServiceMonitor selectors are open (`{}` everywhere, plus
`serviceMonitorSelectorNilUsesHelmValues: false`). This lets
ServiceMonitors shipped elsewhere (perf-sentinel, OTel Collector,
external charts) be picked up without requiring a specific label. As
a safety net, in-house ServiceMonitors still carry
`release: kube-prometheus-stack` so they remain compatible if we
tighten the selector in S2.

The `observability` namespace is annotated with PodSecurity
`enforce: privileged` because node-exporter requires `hostNetwork`,
`hostPID`, and `hostPath` volumes, which the `baseline` profile
forbids.

### OTel Collector contrib

Chart 0.152.0, contrib image 0.150.1. `daemonset` mode: one instance
per node, simplifies node-level metric collection and prevents the
Collector from becoming a bottleneck when traffic ramps up in S2.

Trace pipeline:

```
OTLP receiver -> memory_limiter -> k8sattributes -> batch
              -> exporters: otlphttp/tempo, otlphttp/perf_sentinel
```

The `k8sattributes` processor enriches each span with Kubernetes
metadata (namespace, deployment, pod, node). Critical so that
perf-sentinel findings can be correlated with the workload that
produced them.

Traces are fan-outed to both exporters. Tempo persists for long-term
navigation in Grafana, perf-sentinel ingests in streaming mode to
produce findings.

### perf-sentinel daemon

Image `ghcr.io/robintra/perf-sentinel:0.5.4`. The upstream image is
`FROM scratch`, which means:

- No `kubectl exec` (no shell).
- No Docker `HEALTHCHECK`.
- Liveness and readiness probes via `httpGet` on `/health` (always
  exposed, regardless of `[daemon] api_enabled`).

The daemon listens on 14318 (HTTP) and 14317 (gRPC) instead of the
defaults 4318/4317. The override is purely cosmetic from the host's
perspective: it avoids confusion with the standard OTLP ports
exposed by Tempo and the Collector. Inside the cluster each service
has its own IP, so there would not have been a port conflict either
way.

Configuration is injected via a ConfigMap mounted read-only on
`/etc/perf-sentinel/config.toml`:

- `correlation.enabled = true` (default: false). We want to test
  cross-trace detection in S2.
- `n_plus_one_min_occurrences = 5`: low but reasonable threshold to
  catch real N+1 patterns without excessive noise.

A ServiceMonitor scrapes `/metrics` every 30 s. The exposed metrics
(prefix `perf_sentinel_`) feed the `perf-sentinel-overview`
dashboard.

### PostgreSQL 18.3

Single-replica StatefulSet, official image `postgres:18.3-alpine`,
PVC 5 GiB. Three schemas (`orders`, `payments`, `notifications`)
plus three dedicated roles are created on first boot by the
`postgres-init-schemas` ConfigMap.

Explicit decision: a single Postgres instance with three schemas, not
three instances. Lighter on RAM (~300 MiB vs. ~900 MiB), less
realistic than a multi-DB deployment but acceptable for a lab.

The `lab` user password is generated at bootstrap, persisted to
`.postgres-password` (mode 0600, gitignored), and stored in the
`postgres-credentials` Secret. The `make psql` target reads that
file to open a session without prompting.

### Host networking via port-forward

The k3d port mappings (`80:80`, `3000:3000`, `14318:14318`) target
NodePort or LoadBalancer Services. The lab uses ClusterIP Services
and `--disable=servicelb`, so the mappings alone do not reach the
workloads. `bootstrap.sh` finishes by starting `kubectl port-forward`
in the background via `scripts/port-forward.sh`. The PIDs land in
`tmp/pf-*.pid`.

`teardown.sh` (and `make down`) stop the forwards before deleting
the cluster.

## Out of scope

- No TLS between components. Port 443 is exposed by k3d but unused.
  May be added in S3 with GitLab CE.
- No NetworkPolicy between namespaces. Add in S2 if the evaluation
  scenario calls for stricter isolation.
- No auth on the perf-sentinel HTTP API. Local lab, fine.
- No Postgres backup. Data is ephemeral.
- No application service. That is S2.
- No self-hosted CI/CD. That is S3/S4.
