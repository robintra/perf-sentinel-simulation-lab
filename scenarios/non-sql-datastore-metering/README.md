# non-sql-datastore-metering

Validates the `0.9.2` metering and zero-retention warning behaviour around the
non-SQL datastore drop.

## What it checks

1. **Redis-only fleet** (1250 redis spans, all dropped):
   `perf_sentinel_otlp_spans_filtered_total{reason="non_sql_datastore"}`
   rises to ≥1250, **and** the `/api/export/report` zero-retention warning
   is **absent**, because `0.9.2` excludes `non_sql_datastore` from the
   instrumentation-gap sum, so a Redis-only fleet is not mistaken for broken
   instrumentation.
2. **Internal-only fleet** (1250 `not_io` spans), the **negative control**:
   the zero-retention warning is **present** (`not_io` still counts toward
   the gap), proving the warning still fires for a genuine zero-retention
   gap.

## Why the NDJSON seed

The zero-retention warning lives in the Report (`/api/export/report`), which
short-circuits to a cold-start envelope until the daemon has analyzed ≥1
trace. A 100%-filtered fleet never escapes cold-start, so each case first
seeds **one** analyzable trace over the NDJSON socket, a non-OTLP path that
bumps the analyzed counters **without** touching
`otlp_spans_received_total`. The OTLP flood then equals `received` on its
own, so `gap_filtered >= received` holds exactly when the flood is `not_io`
(warning) and never when it is `non_sql_datastore` (no warning).

## Run

```bash
make verify-non-sql-datastore-metering
```

Self-contained: needs only the local release binary
(`cargo build --release -p perf-sentinel`). Each case runs a fresh throwaway
loopback daemon (received/filtered are cumulative whole-daemon counters). The
NDJSON socket path is kept short (`/tmp/ps-nsm.sock`) for the AF_UNIX limit.
