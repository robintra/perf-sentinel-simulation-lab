# rpc-carrier-parity

`prod-topology-replay` was built when perf-sentinel's ingest kept only
SQL- and HTTP-shaped spans, so every Alibaba call edge rides a SYNTHETIC
carrier attribute `http.url = http://<dm>/<interface>` and the real
protocol (`rpc.system` = the dataset's rpctype) is a passenger. Since
product 0.9.8 the ingest admits OTel RPC semconv
spans natively: `rpc.system` present + `span.kind == CLIENT`, target
`"{rpc.service}/{rpc.method}"` with the span name as fallback, modeled
as an outbound call (`EventType::HttpOut`, so findings surface under the
`*_http` types).

This gate proves the new path carries the full topological detector
surface at real production scale, without re-downloading anything:
`rpcify.py` rewrites the committed slice into three shapes analyzed
against the in-run carrier baseline.

| variant | shape | expectation |
|---|---|---|
| client | carrier stripped; `rpc.service=<dm>`, `rpc.method=<interface>` | same admission + topology findings as the carrier |
| fallback | carrier stripped, no `rpc.service`/`rpc.method`; span renamed `<dm>/<interface>` | identical to `client` (the span-name fallback is the same admission path) |
| server | `client` shape with `span.kind` CLIENT→SERVER | zero findings: rpc.* is set on inbound handler spans too, and admitting them would double-count every hop |

## Why parity is per-class, not total

The HTTP normalizer strips the URL host, so the carrier groups calls by
`POST /<interface>` only: two calls from one service to the SAME
interface name on DIFFERENT dm hosts merge into one false
`redundant_http` group. The RPC target `<dm>/<interface>` keeps them
apart. On this slice that accounts for exactly 10 baseline findings
(e.g. trace `7bc6c426…`: `MS_63670` calling `vs2nQhH1hq` on both
`MS_23205` and `MS_53745`). The RPC path is the more faithful one, so
the gate asserts strict equality on `traces_analyzed`,
`events_processed` and the four topology classes (`chatty_service`,
`excessive_fanout`, `n_plus_one_http`, `serialized_calls`), and floors +
records `redundant_http` with the delta instead of equality-asserting
it.

## Run

```bash
make verify-rpc-carrier-parity
```

Needs only the committed `prod-topology-replay` fixture, python3 and a
local release binary at product 0.9.8 or later (an older binary
drops every rpc.* span as not-I/O; the gate dies with a rebuild hint
instead of failing parity). Variants are generated in
`/tmp/rpc-carrier-parity/`; nothing new is committed. Report at
`/tmp/scenario-rpc-carrier-parity-report.md`.

Reference tests for the admission contract live in the product tree:
`crates/sentinel-core/src/ingest/otlp/tests.rs`
(`grpc_client_rpc_span_is_admitted_as_outbound_call`,
`grpc_server_rpc_span_is_not_admitted`,
`rpc_span_without_service_falls_back_to_span_name`).
