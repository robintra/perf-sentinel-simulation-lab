# astronomy-shop

Validates perf-sentinel against the **OpenTelemetry Astronomy Shop demo**
([open-telemetry/opentelemetry-demo](https://github.com/open-telemetry/opentelemetry-demo)):
`analyze --input` / `report --input` replayed over committed NDJSON slices
of Collector file-exporter output. This covers the two things the lab
cannot produce with its own services. The first is **foreign
instrumentation**: canonical, community-maintained OTel
auto-instrumentation across languages, spans we did not author. The second
is a **false-positive budget on realistic mixed traffic**, where the only
prior negative fixture, `scenarios/clean-load.js`, is two endpoints on one
controller.

## What it asserts

| id | assertion                                                                                                                                                                                                                                     |
|----|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| R1 | `analyze --input degraded-slice.ndjson`: exit 0, `traces_analyzed > 0`, and the finding classes intersect the manifest's `expected_finding_classes` (>= 1 common class - loose ground truth, we do not control Astronomy Shop internals)      |
| F1 | `analyze --input clean-slice.ndjson`: exit 0, `traces_analyzed > 0`, and the TOTAL finding count is `<= fp_budget` from the manifest; the actual classes are emitted into the report even on PASS so a class shift under budget stays visible |
| M1 | `total_messaging_io_ops` equals the PRODUCER span count in each slice (13 clean / 10 degraded): the demo's checkout service publishes to Kafka, so these are real broker spans from instrumentation we did not author, and they must reach the detector rather than be dropped as `not_io`. Findings are deliberately not asserted - the demo publishes once per checkout, so there is no messaging anti-pattern to find |
| F2 | `report --input clean-slice.ndjson` renders a usable dashboard                                                                                                                                                                                |

## How it works

Capture once, replay forever - the demo is ~15-20 services and is never
deployed into the lab k3d cluster:

- `capture.sh` (one-off) shallow-clones the demo at the pinned tag, then
  injects a `file` exporter through the demo's own
  `otelcol-config-extras.yml` extension hook. The exporter list is restated
  `[otlp, debug, spanmetrics, file/traces]` because the collector config
  merge replaces arrays. It finally bind-mounts the dump dir into the
  collector via a compose override.
- Two phases produce two separate dumps in gitignored
  `artifacts/astronomy-shop/`: a **clean** phase (all flagd flags off, the
  demo's normal load-generator profile - the false-positive corpus) and a
  **degraded** phase (the manifest's `flags_enabled` turned on - the recall
  corpus). Phases are cut by stop/mv/start of the collector: the live dump is
  never truncated (buffered writer, fd not guaranteed O_APPEND).
- `curate.py` selects a deterministic slice of complete traces from each dump
  (traces fully inside the window minus an edge guard, ordered by start time)
  and re-emits them as valid `ExportTraceServiceRequest` NDJSON. Only the
  slices and the manifest are committed - full dumps run to hundreds of MB.
- `fixtures/fixture-manifest.json` is the contract: `flags_enabled` drives
  the capture. `demo_version`, `otel_demo_commit` and `fp_budget` are
  stamped back by capture.sh. `fp_budget` is the **exact observed finding
  count** on the curated clean slice - replay is deterministic (fixed
  input, deterministic binary), so any later binary exceeding it fails F1
  by design and forces a human look. Restamping is a deliberate, reviewable
  act (rerun capture.sh).
- R1 and F1 run under the same default detection config: the FP budget is
  only meaningful measured under the config that produced the recall.

### Budget history

`fp_budget` also moves when the product widens what counts as I/O, with the
corpus untouched. Those restamps are edited in place rather than recaptured
(recapturing would change the corpus and destroy the comparison), and each one
records what moved and why:

| budget | when | why |
|--------|------|-----|
| 322 | 0.9.8 | RPC semconv keys admitted at ingest |
| 326 | messaging block (post-0.9.22) | broker publishes became I/O ops. The four extra findings are **all `serialized_calls`** (21 -> 25) - no messaging finding appears on either slice. The publishes themselves add no finding; they add I/O spans to traces, and a topological detector that counts spans per trace crossed its threshold four more times. Worth knowing: the widening documented upstream is about `total_io_ops` and IIS, and this second-order effect on a topological detector was not among the predictions |

## Run

```sh
make verify-astronomy-shop     # replay the committed slices (no cluster, no Docker)
make capture-astronomy-shop    # one-off: regenerate dumps, slices and manifest
```

Replay requires only the local release binary (`cargo build --release` in the
perf-sentinel checkout) and python3. Capture additionally needs Docker
(~8 GiB for the demo, ~25 min end to end), docker compose v2, jq and git.
Report: `/tmp/scenario-astronomy-shop-report.md`.

Bug caught on first run: `analyze` rejected the degraded slice because the
recommendation service emits an empty-list attribute as `"arrayValue":{}`
(canonical protojson omits empty repeated fields) and the ingest required the
`values` field, so one attribute failed the whole file. Fixed upstream in
`fix(ingest): accept OTLP/JSON arrayValue/kvlistValue with omitted values
(#81)`; the committed slice keeps those 6 lines as the regression fixture. R1
now passes (231 traces: `n_plus_one_sql`/`redundant_sql` on product-catalog,
`redundant_http` on the frontend chain).
