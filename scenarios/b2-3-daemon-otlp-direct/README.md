# B2-3 daemon receives OTLP HTTP directly (no Collector) - DEFERRED

## Status

DEFERRED to follow-up session.

## Use case

A minimal setup with no Tempo and no OTel Collector. An instrumented
service points its OTLP exporter straight at the perf-sentinel daemon's
HTTP endpoint (port 14318). The daemon ingests, correlates, and exposes
findings via `/api/export/report`. Validates that the daemon's native
OTLP HTTP receiver works without an external collector.

## Why deferred

The first attempt in this session crashed the local k3d cluster API
(TLS handshake timeout) under cumulative load: 3 Java services in
`shop` plus GitLab CE plus observability stack plus the new dedicated
daemon and cloned service in `b2-3-direct-otlp`. The cluster
recovered after cleanup, but the headroom is too thin to safely add
B2-3 plus B2-4 plus B2-6 in the same session on a 7 GB Docker
Desktop allocation.

A follow-up session with a freshly reset cluster (`make reset-cni` +
seed) will retry B2-3 with more room.

## Files in this folder

- `manifests.yaml` : namespace + dedicated daemon Deployment + cloned
  order-service Deployment that pushes OTLP HTTP straight to the
  dedicated daemon. Kept as a template for the follow-up session.
- `verify.sh` : currently a DEFERRED placeholder that prints a status
  line and exits 0. The full verify logic (apply manifests, port-forward,
  send traffic, snapshot, cleanup) is planned but not run in this
  session.

## Resume in follow-up

```bash
# 1. Reset cluster cleanly
make reset-cni
make seed-services
make seed-electricity-maps

# 2. Run the full B2-3 (requires the verify.sh body to be filled in
#    from the in-flight version archived in this folder's git history)
make verify-b2-3-daemon-otlp-direct
```
