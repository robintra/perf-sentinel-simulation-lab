# batch-otlp-file

Validates perf-sentinel 0.9.5's **OTLP/JSON batch ingestion**: the whole
`--input` family auto-detects `ExportTraceServiceRequest` payloads — both a
single (pretty-printed) object and the NDJSON stream written by the OTel
Collector `file` exporter (one request per line). This is the backend-less
batch path: **dd-trace → datadogreceiver → file exporter → `analyze`**, no
Tempo/Jaeger in the loop.

## What it asserts

| id | assertion |
|----|-----------|
| A1 | `analyze --input <NDJSON dump>` (strict sanitizer config): exit 0, `traces_analyzed > 0`, an N+1/redundant SQL finding for the dd-trace service |
| A2 | batch findings coherent with the loopback daemon's `/api/findings` on the **same tee'd traffic** |
| A3 | same assertions on native OTel traffic through the **cluster** collector (file-exporter values overlay, dump read off the k3d nodes) — SKIP without a cluster |
| A4 | truncated trailing line (rotation / in-flight write): exit 0, `truncated trailing OTLP JSON document` warning on stderr, complete lines analyzed |
| A5 | a half-line-only file (no complete request) and mid-stream garbage both exit 1 |
| A6 | detection non-regression: a Jaeger UI export stays Jaeger even with a span tag valued `resourceSpans`; an OTLP dump stays OTLP even with an attribute named/valued `data` |
| A7 | `report --input <dump>` renders a usable dashboard |

## How it works

- A loopback daemon (strict mode) plus a throwaway contrib collector
  (`collector-ddtrace.yaml`): `datadog` receiver on :8126, traces tee'd to
  `otlphttp` (the daemon) **and** `file/dump` (bind-mounted NDJSON). No batch
  processor, so one intake request = one NDJSON line.
- `dd_send.py` sends synthetic dd-trace v0.4 msgpack N+1 traces (SQL
  pre-obfuscated, as dd-trace ships it) — one PUT per trace.
- The native-OTel leg layers `collector-overlay.yaml` on the cluster
  collector (file exporter + hostPath mount; the contrib image is
  scratch-based so the dump is read with `docker exec <k3d-node> cat`, not
  `kubectl cp`), drives order-service N+1 faults, and reverts the overlay on
  exit.

## Run

```sh
make verify-batch-otlp-file
```

Requires the local release binary (`cargo build --release` in the
perf-sentinel checkout), Docker, and `python3-msgpack`. The cluster leg (A3)
SKIPs cleanly when no cluster is reachable. Report:
`/tmp/scenario-batch-otlp-file-report.md`.
