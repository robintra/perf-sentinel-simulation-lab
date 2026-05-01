# B2-6 sidecar pattern (1 daemon per service)

## Use case

A single application service is monitored by a perf-sentinel daemon
deployed as a sidecar in the same pod. The service pushes OTLP traces
to `localhost:14318` (the daemon container in the same pod). Findings
are scoped to that one service. Pattern useful for strict pod-level
isolation, single-service monitoring without a centralized daemon, or
edge deployments where cross-pod network paths are unavailable.

## Run

```bash
make verify-b2-6-sidecar-pattern
```

## What is verified

The verify script applies a dedicated namespace `b2-6-sidecar` with a
2-container pod (order-service + perf-sentinel daemon), sends 60
in-cluster POST requests to `/api/fault/n-plus-one-sql?items=15` (via
an ephemeral curl pod with restricted PSA security context), waits 30s
for the OTel BatchSpanProcessor to flush, snapshots the sidecar daemon's
report, asserts non-zero events and traces, and prints the pod's memory
footprint.

## Configuration trade-off (read this)

The sidecar daemon binds `0.0.0.0:14318` rather than `127.0.0.1:14318`
because the lab uses a Kubernetes Service for the verify probe. A
strict-isolation deployment (no Service routing to the daemon, only
intra-pod localhost ingestion) would bind `127.0.0.1` and rely on the
fact that no other pod can reach the loopback interface.

The compromise is documented inline in `manifests.yaml` and called out
in the daemon ConfigMap. Pod-level isolation is enforced by the absence
of cluster Services or NetworkPolicies that would route external
traffic to the daemon port.

The OTel agent's `BatchSpanProcessor` flushes every ~5s by default and
the daemon's `trace_ttl_ms=30000` (bumped from the default 5000) gives
the correlator a wide enough window to retain children of large N+1
spans.

## Pod footprint

The verify script uses `kubectl top pod` to print the cumulative memory
of the 2-container pod. Adoption guideline: the daemon adds roughly
60-150 MiB on top of the application container.

## Output

`/tmp/scenario-b2-6-sidecar-pattern-report.md` plus
`/tmp/b2-6-sidecar-pattern/sidecar-report.json`.

## Cleanup

The verify script deletes the namespace at exit. Set
`KEEP_NAMESPACE=yes` to inspect the running pod.
