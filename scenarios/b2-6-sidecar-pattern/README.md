# B2-6 sidecar pattern (1 daemon per service) - DEFERRED

## Status

DEFERRED to follow-up session.

## Use case

A single application service is monitored by a perf-sentinel daemon
deployed as a sidecar in the same pod. The service pushes OTLP traces
to `localhost:14318` (the daemon container in the same pod). Findings
are scoped to that one service. Pattern useful for strict pod-level
isolation or for a single-service monitoring setup that does not
warrant a centralized daemon.

## Why deferred

The blocker is the same cluster RAM constraint that blocked B2-3 in
this session. The sidecar pattern adds ~150 MiB per pod (a perf-sentinel
daemon container). On a saturated 7 GB Docker Desktop cluster, that
extra footprint risks the same TLS handshake timeout we observed on
B2-3.

A follow-up session with a fresh cluster will pick this up after B2-3.

## Files planned for the follow-up session

- `namespace.yaml` (`b2-6-sidecar`)
- `pod-with-sidecar.yaml` : Deployment with 2 containers (order-service
  + perf-sentinel daemon), shared `localhost`, daemon listening on
  14318 of the pod's loopback interface.
- `verify.sh` : kubectl apply, port-forward sidecar daemon, send
  traffic, assert findings limited to the colocated service, cleanup.

## Resume in follow-up

```bash
make reset-cni
make seed-services
make seed-electricity-maps
make verify-b2-6-sidecar-pattern
```
