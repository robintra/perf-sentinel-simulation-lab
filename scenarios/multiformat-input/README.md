# multi-format input (Jaeger + Zipkin live + boundary fixtures)

## Use case

The same OTel Collector pipeline emits traces in parallel to three
backends: Tempo (existing), Jaeger (added by this scenario), and
Zipkin (added by this scenario). perf-sentinel `analyze` runs on the
raw trace exports from Jaeger and Zipkin, and the findings should be
coherent across formats.

Plus a boundary test on JSON parser depth: a depth-31 fixture must
parse, a depth-33 fixture must reject (per upstream `MAX_JSON_DEPTH=32`).

## Run

```bash
make verify-multiformat-input
```

## What is verified

1. **Live multi-backend**: applies `manifests.yaml` (Jaeger + Zipkin
   Deployments + Services + additive NetworkPolicies), upgrades the OTel
   Collector with `collector-overlay.yaml` (`otlphttp/jaeger` exporter
   + `zipkin` exporter alongside Tempo). Sends a focused 20-request
     burst (`/api/fault/n-plus-one-sql?items=15` and
     `/api/fault/redundant-sql?items=10`), then polls the backends
     until rich traces appear, meaning more than 5 spans rather than
     single-span health probes. It fetches them via the Jaeger and
     Zipkin query APIs, runs `perf-sentinel analyze` on each export,
     and asserts at least one finding category common between the two
     formats.
2. **Boundary fixtures**: `fixtures/depth-31-jaeger.json` must parse,
   `fixtures/depth-33-jaeger.json` must be rejected with `exceeds
   maximum depth`.

Zipkin boundary fixtures are not exercised because Zipkin v2 spec
constrains tag values to strings, so depth-31 rejects on type mismatch
before the depth check fires. The depth guard itself is format-agnostic.

## Configuration

- `manifests.yaml` provisions Jaeger all-in-one (`MEMORY_MAX_TRACES=50000`)
  and Zipkin (`MEM_MAX_SPANS=500000`, `JAVA_OPTS=-Xmx1500m`,
  resource limit 1Gi). The defaults eject rich N+1 traces under sustained
  k6 traffic, hence the bumps.
- `collector-overlay.yaml` adds `otlphttp/jaeger` (port 4319 -> 4318 on
  the Jaeger pod, exposed as a Service in `observability`) and `zipkin`
  exporters in parallel with the Tempo exporter. The default OTel chart
  pipeline is overridden to add both.
- Two additive NetworkPolicies (`jaeger-allow-internal`,
  `zipkin-allow-internal`) and a Collector egress policy
  (`otel-collector-egress-to-jaeger-zipkin`) are required because the
  lab default-deny baseline blocks Collector egress to the new backends.

## Output

`/tmp/scenario-multiformat-input-report.md` plus
`/tmp/multiformat-input/{jaeger-traces,zipkin-traces,jaeger-findings,zipkin-findings}.json`.

## Cleanup

By default the script keeps Jaeger, Zipkin, and the multi-export
collector overlay in place so re-runs are fast. Set `KEEP_BACKENDS=no`
to roll back to the nominal lab state.
