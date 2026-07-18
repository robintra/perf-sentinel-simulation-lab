# alumet-db-waste

Validates perf-sentinel **0.9.13**'s database-waste feature: the Alumet-measured
energy of a declared database cgroup, attributed to the SQL-only avoidable share
of the workload and reported as `green_summary.database_waste`.

It builds on the 0.9.12 Alumet backend (see [`alumet-conformance`](../alumet-conformance)).
0.9.13 adds:

- **SQL split** — `green_summary.total_sql_io_ops` / `avoidable_sql_io_ops`, the
  SQL-only slice of the io-op counters (SQL spans, and `n_plus_one_sql` +
  `redundant_sql` findings). The batch side of this is asserted in
  [`sci-functional-unit`](../sci-functional-unit); this scenario covers the
  daemon side end to end.
- **`[green.alumet.database]`** — declares one database cgroup label
  (`label_value`, optional `region`). Each scored window the daemon multiplies
  that cgroup's measured window energy by `sql_waste_ratio =
  min(avoidable_sql_io_ops / total_sql_io_ops, 1.0)` and reports
  `green_summary.database_waste = { energy_kwh, waste_kwh, waste_gco2, region,
  sql_waste_ratio }`. A **CPU-only lower bound**, **excluded** from the
  top-level `energy_kwh`, from `co2`, and from the public `disclose` output.

## Prerequisites

**Self-contained — no cluster.** A local release binary on loopback (ports
14598/14599) + `python3 -m http.server` serving the committed 0.9.12 Alumet
capture augmented with **one synthetic database-cgroup series** carrying a known
joules-per-poll value, so every figure is checkable. Traces are seeded over the
daemon's protobuf OTLP endpoint with the committed `datadog-bridge` N+1 fixture
(and `daemon-analysis-shedding`'s 300-trace payload for leg D). Docker is not
required.

Build the binary under test first:

```bash
cargo build --release -p perf-sentinel   # in the perf-sentinel checkout
make verify-alumet-db-waste              # or: ./scenarios/alumet-db-waste/verify.sh
```

Override `PERF_SENTINEL_LOCAL_BIN` to point at a specific binary (e.g. a
pre-0.9.13 build, which produces **no** `database_waste` — the built-in negative
control).

## Legs

| leg | what it locks |
|-----|---------------|
| **B** | `database_waste` end to end: present with `energy_kwh > 0`; `sql_waste_ratio == avoidable_sql/total_sql`; `waste_kwh == energy_kwh * sql_waste_ratio` (both recomputed); `waste_gco2 > 0`; the DB label never enters the per-service energy maps and the top-level `energy_kwh` equals the pure service sum (exclusion); and `database_waste` is stripped from `disclose` output even though the per-window archive carries it. |
| **C** | Sticky live cell: `database_waste` never flaps to `null` between scrapes, and after the scraper dies it ages out within the TTL (`2 × staleness = 6 × scrape interval`, ≈30 s here) under continued traffic — not pinned to a dead measurement forever. |
| **D** | Carry-over under shedding: with a 1-deep analysis queue and a 20-trace window flooded to shed whole batches, the DB energy summed across the archived NDJSON windows is conserved (quantized to whole scrapes, no vanishing) and the daemon **sheds instead of OOMing**. |
| **E** | Config validation: a `label_value` colliding with `service_mappings`, a typo'd `[green.alumet.databse]`, a `[green.alumet.database]` with no endpoint, and an unknown key inside `[green.alumet]` (the `deny_unknown_fields` compat break) are all **rejected at load**; a charset-valid but unknown `region` only **warns** and yields `database_waste` with `waste_gco2` absent. |
| **F** | `query monitor` Energy tab: the `/api/export/report` snapshot backing `build_energy_lines` carries every field the "Database waste:" line renders; a best-effort headless TUI capture greps the rendered line (the TUI is not driven headless in CI — its rendering + region sanitization are covered by upstream unit tests). |

## Notes

- The database energy is **synthetic** (the lab measures no real cgroup): a known
  `72000 J/poll → 0.1 kWh per 5 s scrape`, riding the same memory-as-joules
  capture the Alumet conformance legs use. Physical realism is not the point;
  checkable arithmetic is.
- The synthetic cgroup label (`pg-cgroup`) is deliberately distinct from any
  `service_mappings` value, since a collision is a config error (leg E).
