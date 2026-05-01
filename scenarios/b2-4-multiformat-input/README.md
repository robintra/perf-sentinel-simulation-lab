# B2-4 multi-format input parser - DEFERRED

## Status

DEFERRED to follow-up session.

## Use case

The same traces are emitted to three backends (Tempo OTLP, a Jaeger
backend, a Zipkin backend) via an OTel Collector configured with
parallel exporters. perf-sentinel `analyze --input` is run on the raw
trace dumps from each backend, and the findings produced by all three
should be coherent (same anti-pattern categories detected, similar
counts, with explainable differences).

Plus a boundary test on JSON parser depth: depth-31 fixtures must
parse, depth-33 fixtures must reject (per the upstream 0.5.16 boundary
tests).

## Why deferred

This is the heaviest scenario:

- Deploying Jaeger backend (Helm chart `jaegertracing/jaeger`,
  ~250 MiB).
- Deploying Zipkin backend (Helm chart `openzipkin/zipkin`,
  ~150 MiB).
- Reconfiguring `helm/values/otel-collector.yaml` to add parallel
  exporters towards both new backends.
- Generating synthetic depth-31 and depth-33 fixtures for native,
  Jaeger, Zipkin formats (6 fixtures).
- Implementing the cross-format coherence assertion.

Full implementation estimated at 2-3 hours. The cluster RAM headroom
in this session was insufficient to also accommodate the two new
backends. Follow-up session can deploy them on a fresh cluster.

## Files in this folder

Currently only this README. The follow-up session will add:

- `fixtures/depth-31-{native,jaeger,zipkin}.json`
- `fixtures/depth-33-{native,jaeger,zipkin}.json`
- `manifests/jaeger.yaml` (lightweight all-in-one)
- `manifests/zipkin.yaml`
- `helm/values/otel-collector-multiexport.yaml` (overlay)
- `verify.sh`

## Resume in follow-up

```bash
make reset-cni
make seed-services
make seed-electricity-maps
# Plus deploy Jaeger and Zipkin backends, reconfig OTel Collector.
make verify-b2-4-multiformat-input
```
