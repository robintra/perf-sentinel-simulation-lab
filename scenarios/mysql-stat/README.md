# mysql-stat

Validates perf-sentinel 0.9.5's **`mysql-stat`** subcommand (the MySQL twin of
`pg-stat`) against a **real MySQL LTS (9.7)** `performance_schema`, plus the
`mysql_stat` tab of the HTML dashboard (`report --mysql-stat`,
`--mysql-stat-top`). Self-contained: local release binary + throwaway MySQL
containers, no cluster.

## What it asserts

| id | assertion |
|----|-----------|
| B1 | text output: 4 rankings in stable order (`top by total_exec_time`, `top by calls`, `top by mean_exec_time`, `top by rows_examined`), plausible millisecond timers (picoseconds / 1e9), `schema:` column |
| B2 | `--format json`: `rankings[3].label == "top by rows_examined"` (all 4 labels exact) |
| B3 | CSV and JSON exports of the same digest table yield identical entries |
| B4 | `--traces` sets `[seen in traces]` on a **genuine MySQL digest** (backticked, spaced) matching a dd-trace obfuscated template (no backticks). This is the backtick/spacing/case canonicalization on real data |
| B5 | robustness: the `DIGEST_TEXT = NULL` catch-all row (forced with `--performance-schema-digests-size=10`) is ignored; an all-null export fails with a clear error; `NULL`/`\N` schema renders as absent; ANSI escapes in a trapped export never reach the terminal (normal and error paths) |
| B6 | `report --input <traces> --mysql-stat <csv>`: `mysql_stat` tab, 4 ranking chips, real digest data; `--mysql-stat-top 0`, `10001`, and orphan `--mysql-stat-top` rejected |
| B7 | `demo --html`: the demo dashboard ships a populated `mysql_stat` tab |

## How it works

- `mysql:9.7` (current LTS) container, `shop` schema (`orders`, `line_items`, `users`) and a
  real workload mirroring the instrumented services' patterns: the three
  N+1 point lookups from the dd-trace fixtures, an `IN (a, b, c)` list, an
  `UPDATE`, and full-scan aggregates.
- Export via `SELECT JSON_ARRAYAGG(JSON_OBJECT(...))` from
  `performance_schema.events_statements_summary_by_digest` (NOT
  `INTO OUTFILE`, which emits unsupported TSV), converted client-side to a
  properly quoted CSV twin.
- A second container started with `--performance-schema-digests-size=10` is
  flooded with 40 structurally distinct statements to force the real NULL
  catch-all row.
- The trace side of B4/B6 is `scenarios/datadog-bridge/fixtures/crossfmt-jaeger.json`,
  whose obfuscated templates (`SELECT * FROM orders WHERE id = ?`, …) must
  canonicalize onto the backticked MySQL digests.

Interactive dashboard behaviors (filter ↔ CSV export coherence, Copy link)
are exercised in a browser during release gates. The script asserts the
static HTML surface.

## Run

```sh
make verify-mysql-stat
```

Requires the local release binary and Docker. Report:
`/tmp/scenario-mysql-stat-report.md`.
