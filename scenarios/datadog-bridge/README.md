# datadog-bridge

End-to-end validation of perf-sentinel **0.9.3**'s Datadog / dd-trace ingestion
bridge and the db-system classification hardening that shipped with it.

Teams on Datadog's `dd-trace` (no OpenTelemetry SDK) bridge their traces
through an OTel Collector running the
[`datadogreceiver`](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/datadogreceiver).
That receiver converts dd-trace APM spans to OTLP. perf-sentinel then reads
the SQL from `dd.span.Resource` when `db.statement` is absent, gated on a
SQL db signal.

Every bridged fixture mimics the **real** `datadogreceiver` output captured from
contrib **v0.155.0**: instrumentation scope `Datadog`, SQL already obfuscated
(`?`) in `dd.span.Resource`, and the engine under the stable OTel 1.27+ key
`db.system.name` (value e.g. `"postgres"`), **not** `db.system` / `db.type`.

## Run

```bash
make verify-datadog-bridge        # or: ./scenarios/datadog-bridge/verify.sh
```

Self-contained: needs only the local release binary
(`cargo build --release -p perf-sentinel`). No cluster. A throwaway
loopback daemon serves the OTLP `/v1/traces` legs, and batch
`analyze`/`explain` covers the Jaeger/Zipkin legs. An **optional** live leg
(`live/run-live.sh`) sends a synthetic dd-trace v0.4 payload through a real
`datadogreceiver` container into the daemon. It **skips** cleanly when
Docker (or python `msgpack`) is unavailable, so the deterministic
assertions always gate.

## Assertions

| Id | Check |
|----|-------|
| **A** | a dd-trace N+1 carrying only `db.system.name` is recognized as SQL → non-zero SQL finding (the 0.9.3 stable-semconv fix; zero findings = regression) |
| **B** | non-SQL stores (`db.type=redis`, `db.system.name=aws.dynamodb`) dropped, never tokenized; no key/secret in `/api/findings` or the HTML report |
| **C** | `operation` label canonicalization (`explain`): `db.system="postgres"` → `postgresql`, a db-system-less SQL span → `sql`, on Jaeger + Zipkin |
| **D** | stable `db.system.name` across formats: SQL engines → findings, `aws.dynamodb` dropped |
| **E** | cloud SQL engine `snowflake` (dd-trace `db.type`) → SQL finding |
| **F** | F3 known limitation, locked: `auto` + uniform timing → `redundant_sql`; `strict` + ≥ 15 identical → `n_plus_one_sql` |
| **G** | `perf_sentinel_otlp_spans_filtered_total{reason="non_sql_datastore"}` and `{reason="missing_db_statement"}` rise |

### F3 (assertion F): why `redundant_sql`, not `n_plus_one_sql`

dd-trace pre-obfuscates SQL, so N distinct `WHERE id = <literal>` queries
arrive as one identical template (`= ?`, `distinct_params = 1`). That trips
`looks_sanitized`, routing the group to the sanitizer-aware classifier. The
bridged scope is `Datadog` (no ORM marker), so under the default `auto`
mode only timing variance could rescue it. With uniform timing it stays
`redundant_sql`. `strict` recovers `n_plus_one_sql` at high occurrence (≥
3× `n_plus_one_min_occurrences`). This is documented behavior
(`docs/INTEGRATION.md`, "Coming from Datadog"), and the scenario locks it.

## Fixtures

`fixtures/generate.py` regenerates everything
(`pip install opentelemetry-proto` is needed for the `.pb` payloads, the
JSON paths are stdlib). `verify.sh` replays the committed fixtures and
never runs the generator.

- `dd-bridge-nplusone.pb` for A + F(auto): `db.system.name=postgres`,
  obfuscated, 6× uniform.
- `dd-bridge-16.pb` for F(strict): 16× uniform.
- `dd-snowflake.pb` for E: `db.type=snowflake`.
- `nonsql-and-gap.pb` for B + G: redis + dynamodb (drops) + a
  statement-less SQL gap.
- `crossfmt-{jaeger,zipkin}.json` for C + D: pg legacy + pg stable-key +
  db-system-less groups, plus an `aws.dynamodb` drop.
- `live/`: `collector.yaml`, `dd_send.py`, `run-live.sh` for the optional
  live leg.
