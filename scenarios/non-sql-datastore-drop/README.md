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
  rises by 7 (6 redis + 1 es) while `{reason="not_io"}` stays 0. That
  proves the elasticsearch span with `url.full` was dropped on
  `db.system`, not re-bucketed as HTTP.

## Run

```bash
make verify-non-sql-datastore-drop
```

Self-contained: needs only the local release binary
(`cargo build --release -p perf-sentinel`). No cluster, no port-forward.
The OTLP leg launches its own loopback daemon (ports 14392/14393,
override with `DAEMON_HTTP_PORT`/`DAEMON_GRPC_PORT`).
