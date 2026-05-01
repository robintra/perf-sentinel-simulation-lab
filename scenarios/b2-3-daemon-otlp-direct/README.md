# B2-3 daemon receives OTLP HTTP directly (no Collector)

## Use case

A minimal setup with no Tempo and no OTel Collector. An instrumented
service points its OTLP exporter straight at the perf-sentinel daemon's
HTTP endpoint (port 14318). The daemon ingests, correlates, and exposes
findings via `/api/export/report`. Validates that the daemon's native
OTLP HTTP receiver works without an external collector.

## Run

```bash
make verify-b2-3-daemon-otlp-direct
```

## What is verified

The verify script applies a dedicated namespace `b2-3-direct-otlp`
with:

- A standalone perf-sentinel daemon Deployment (own correlator state,
  isolated from the lab daemon in `observability`).
- A cloned `order-service` Deployment with
  `OTEL_EXPORTER_OTLP_ENDPOINT=http://perf-sentinel-daemon-direct.b2-3-direct-otlp.svc.cluster.local:14318`.
- An additive NetworkPolicy (`postgres-allow-b2-3-direct-otlp` in `db`)
  so the cloned service can reach Postgres.

It then sends 50 POST requests to `/api/fault/n-plus-one-sql`, snapshots
`/api/export/report` from the dedicated daemon, and asserts non-zero
events and traces.

## Configuration

The cloned service's manifest pins the OTLP endpoint to the daemon's
ClusterIP service, not localhost. The daemon listens on `0.0.0.0:14318`
inside the pod (no Collector to mediate). For reference, the lab path
uses 14317 (gRPC) and 14318 (HTTP) custom ports rather than the OTLP
defaults 4317/4318 to avoid clashes if both daemons run side by side.

## Output

`/tmp/scenario-b2-3-daemon-otlp-direct-report.md` plus
`/tmp/b2-3-daemon-otlp-direct/direct-report.json` (raw daemon report).

## Cleanup

The verify script deletes the namespace at exit. Set
`KEEP_NAMESPACE=yes` to inspect the running pods.
