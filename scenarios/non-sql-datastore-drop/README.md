# non-sql-datastore-drop

Validates the `0.9.2` ingest change that drops non-SQL datastore spans on
`db.system` alone, before any SQL tokenizer runs, coherently across the
three ingestion paths.

## Fixture

One trace mixing:

- 1 HTTP SERVER root.
- 6 PostgreSQL children → a real N+1 (`SELECT * FROM orders WHERE id = 1..6`),
  the **only** thing that must survive and produce a finding.
- 6 Redis children (`db.system=redis`, `GET user:1..6`), which must be
  dropped.
- 1 Elasticsearch child carrying **both** `db.statement` and `url.full`.
  It must be dropped on `db.system`, and **not** reclassified as an HTTP
  finding (the edge the task asks to check first on the OTLP path).

`fixtures/generate.py` emits the Jaeger + Zipkin JSON (stdlib). The OTLP
protobuf payload (`mixed.pb`) comes from `fixtures/generate-otlp.py`
(`pip install opentelemetry-proto`).

## What it checks

- **Batch Jaeger + Zipkin** (local `analyze` binary): `events_processed == 7`
  (root + 6 pg; the 6 redis + 1 es are dropped), the only finding is the
  PostgreSQL `n_plus_one_sql`, and no `redis`/`elasticsearch`/`user:` literal
  leaks into the findings.
- **OTLP daemon**: a throwaway loopback `perf-sentinel watch` daemon
  ingests `mixed.pb`. Findings carry only the PostgreSQL N+1.
  `perf_sentinel_otlp_spans_filtered_total{reason="non_sql_datastore"}`
  reads exactly 7 (6 redis + 1 es). The exact count is the proof: the
  elasticsearch span with `url.full` was dropped on `db.system` rather
  than re-bucketed as HTTP, and had `url.full` won it would read 6.
  `{reason="not_io"}` reads exactly 1, the SERVER root. perf-sentinel
  has no inbound HTTP event type, so a SERVER span is never an event of
  its own; the endpoint comes from span attributes. Until 0.12.0 a
  SERVER span carrying a URL was read as an outbound call, which is why
  this used to read 0. The Jaeger and Zipkin fixtures set no
  `span.kind` at all, so their roots stay eligible and their legs still
  count 7 events.

## Run

```bash
make verify-non-sql-datastore-drop
```

Self-contained: needs only the local release binary
(`cargo build --release -p perf-sentinel`). No cluster, no port-forward.
The OTLP leg launches its own loopback daemon (ports 14392/14393,
override with `DAEMON_HTTP_PORT`/`DAEMON_GRPC_PORT`).
