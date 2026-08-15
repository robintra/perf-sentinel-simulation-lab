# prod-topology-replay

Replays a committed slice of **real production topology**: the
[Alibaba
cluster-trace-microservices-v2022](https://github.com/alibaba/clusterdata/tree/master/cluster-trace-microservices-v2022)
call graphs. That dataset carries 17k+ microservices, 20M+ call
graphs over 13 days of production, hashed service names, hierarchical
`rpc_id` parentage, and real timing. This is the one corpus shape the
lab cannot produce and astronomy-shop cannot approximate:
production-scale **topology** (fanout, call chains, service
cardinality, trace shapes). That is exactly what the topological
detectors (fanout, chatty, serialized) and the ingest path see in the
wild.

**Scope, stated honestly**: the dataset carries topology and timing,
not rich attributes. There is no SQL text and no URLs. The converter
emits every call as an HTTP client span with a *synthetic carrier*
url (`http://<dm>/<interface>`) so perf-sentinel's I/O filter keeps
it. `rpctype` and the Alibaba service id ride along as extra
attributes. This scenario validates the topological detector surface
and ingest on real-world trace shapes, **not** N+1-by-query-shape
(astronomy-shop and the batch scenarios own that).

## What it asserts

| id | assertion                                                                                                                                     |
|----|-------------------------------------------------------------------------------------------------------------------------------------------------|
| T1 | `analyze --input alibaba-slice.ndjson`: exit 0 and `traces_analyzed` equals the manifest's stamped value (deterministic committed input)        |
| T2 | every finding class stamped at curation time is still found (recall on real production topology)                                                |
| T3 | total findings equal the stamped count. Replay is deterministic, so any drift forces a human look, and restamping is a deliberate act (see below) |
| T4 | structural guard: fixture line count equals the manifest's trace count (one `ExportTraceServiceRequest` per curated trace)                      |
| T5 | `report --input` renders a usable dashboard naming an `MS_` service                                                                             |

## How it works

Fetch once, replay forever, the same design as astronomy-shop:

- `fetch.sh` (one-off, `make fetch-prod-topology`) downloads
  `CallGraph_0.tar.gz` (~223 MB, the first 3 minutes of the 13-day
  dataset) into gitignored `artifacts/alibaba/`, converts a slice, and
  stamps the manifest from what the local binary observes.
- `convert.py` streams the CSV twice (curate.py's two-pass idiom):
  - dedups `(traceid, rpc_id)` first-wins, because the dataset
    records each RPC twice, once from each side (a known quirk).
  - keeps only traces whose call tree is **consistent**: exactly one
    root, every other `rpc_id`'s parent present. This is the cheap
    version of the CASPER reconstruction filter for the dataset's
    documented topological inconsistencies (missing parents,
    forests). Inconsistent traces are counted and skipped, never
    repaired.
  - selects deterministically (earliest timestamp, traceid; 5–300
    spans; first 300 traces) and emits one
    `ExportTraceServiceRequest` per trace, spans grouped per `um`
    (the caller emits the client span), md5-derived ids, timestamps
    anchored on a fixed epoch. The output is byte-stable.
- `fixtures/fixture-manifest.json` is the contract: curation
  parameters plus the stamped `traces_analyzed` / `findings_total` /
  `expected_finding_classes`. T3 failing after a binary upgrade means
  the detectors now see this real topology differently. Look first,
  then restamp deliberately by rerunning `fetch.sh` (it reuses the
  downloaded artifact, and only the manifest and slice regenerate).

## Run

```sh
make verify-prod-topology-replay   # replay the committed slice (no cluster, no Docker)
make fetch-prod-topology           # one-off: download + convert + stamp (~223 MB)
```

Replay needs only the local release binary and python3.
Report: `/tmp/scenario-prod-topology-replay-report.md`.

Since product 0.9.8 the ingest also admits the real OTel RPC semconv
keys. `scenarios/rpc-carrier-parity/` rewrites this slice onto them
and asserts parity with the synthetic carrier.
