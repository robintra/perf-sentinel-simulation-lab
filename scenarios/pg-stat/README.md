# perf-sentinel report --pg-stat live integration

## Use case

Pair the trace-derived anti-pattern findings with database hotspot
data from `pg_stat_statements` in a single HTML dashboard. The
`pg_stat` tab surfaces the top SQL templates by total exec time,
calls, mean exec time, rows returned, and shared block hit/read
counters. The Explain → pg_stat cross-navigation maps each detected
anti-pattern (notably `n_plus_one_sql`, `redundant_sql`, `slow_sql`)
to its matching template row in the pg_stat tab.

## Run

```bash
make verify-pg-stat
```

## What is verified

The verify script:

1. Confirms `pg_stat_statements` is loaded on the lab Postgres.
2. Resets the pg_stat counters.
3. Drives a workload via `make validate-findings` (1500+ SQL queries
   across the 10 anti-pattern scenarios).
4. Dumps `pg_stat_statements` via `psql \copy ... TO STDOUT WITH CSV
   HEADER` to a local CSV.
5. Runs `perf-sentinel report --input <jaeger-traces> --pg-stat <csv>
   --output dashboard.html`.
6. Asserts the HTML dashboard contains pg_stat references (tab,
   templates, cross-nav).

## Configuration

Lab manifest changes that enable pg_stat_statements:

- `manifests/postgres.yaml`: postgres container args
  ```yaml
  args:
    - -c
    - shared_preload_libraries=pg_stat_statements
    - -c
    - pg_stat_statements.track=all
    - -c
    - pg_stat_statements.max=10000
  ```
  `shared_preload_libraries` is a startup-only setting, so toggling it
  requires a Postgres restart.

- `manifests/postgres-init-schemas.yaml`: `CREATE EXTENSION IF NOT
  EXISTS pg_stat_statements;` runs only on first init (when PGDATA is
  empty). On a pre-existing data dir the extension must be created
  manually:
  ```bash
  kubectl -n db exec sts/postgres -- psql -U lab -d lab \
    -c "CREATE EXTENSION pg_stat_statements;"
  ```

## Alternative input: pg_stat via Prometheus

`perf-sentinel report` also accepts `--pg-stat-prometheus <URL>`
pointing at a Prometheus endpoint exposed by `postgres_exporter` (with
the `pg_stat_statements` collector enabled). The lab does not deploy
postgres_exporter today, so this scenario uses the direct CSV path.

## Output

`/tmp/scenario-pg-stat-report.md` plus the dashboard at
`/tmp/pg-stat/dashboard.html` and the CSV at
`/tmp/pg-stat/pg-stat.csv`.
