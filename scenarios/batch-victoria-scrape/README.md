# batch over Victoria Traces

## Use case

The trace backend is Victoria Traces rather than Tempo. A periodic batch job
fetches recent traces through the Jaeger query API and runs detection on them.

## Run

```bash
make verify-batch-victoria-scrape
```

The Victoria Traces port-forward (`localhost:10428`) must be active.
`make up-cni` or `scripts/port-forward.sh start` ensures this. The scenario
sends three targeted N+1 requests and waits for Victoria Traces to index them.

## What is verified

```
perf-sentinel jaeger-query \
  --endpoint http://host.docker.internal:10428/select/jaeger \
  --service order-service
```

Two things separate this from its Tempo twin.

**The endpoint carries a path.** Victoria Traces serves the Jaeger query API
under `/select/jaeger`, not at the root, so the prefix belongs to `--endpoint`
and the CLI appends `/api/traces` to it. Ingestion lives under a different
prefix again, `/insert/opentelemetry`, which is what the collector exporter
targets.

**The window is proven, not assumed.** Three legs run:

| Leg | Window | Expected |
|---|---|---|
| A | `--lookback 5m` | findings |
| B | an hour ending an hour *before* the traffic | no traces found |
| C | `--from`/`--to` framing the traffic | findings |

Leg B is the load-bearing one. Until 0.16.0 the CLI sent the window as
`lookback`, which Victoria Traces reads only on its service-graph endpoint and
never on `/api/traces`. The parameter was dropped and every search ran from the
Unix epoch, bounded by nothing but `--max-traces`. A scenario that only checked
"findings came back" would have passed against that bug, because an unbounded
search returns the same traces. Requiring an empty result for a window that
excludes the traffic is what distinguishes a window that reached the backend
from one that was silently discarded.

## Output

`/tmp/scenario-batch-victoria-scrape-report.md`.
