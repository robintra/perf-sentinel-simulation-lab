# `sci-functional-unit` scenario

Locks the **0.8.13 gate G1**: SCI intensity per functional unit. Alongside the
existing footprint `green_summary.co2.total` (methodology `sci_v1_numerator`),
0.8.13 emits `green_summary.co2.sci_per_trace` (the per-trace SCI intensity,
methodology `sci_v1_intensity`) and `green_summary.co2.functional_unit`
(`"trace"`).

Two surfaces:

- **batch** — `analyze --format json` with a carbon region configured
  (`[green] default_region`, see `fixtures/green.toml`) over
  `artifacts/fixtures/em-real-time-traces.json` (which yields `n_plus_one_sql`
  among other patterns). Asserts the four fields plus the invariant
  `sci_per_trace.mid == co2.total.mid / analysis.traces_analyzed`.
- **daemon** — `GET /api/export/report` must carry the same `co2.sci_per_trace`
  and `co2.functional_unit`. SKIPped (not failed) when the daemon port-forward is
  unreachable, so the scenario also runs hermetically.

## Run

```
make verify-sci-functional-unit
# pre-release (image not yet on GHCR): build + import perf-sentinel:0.8.13-rc, then
PERF_SENTINEL_VERSION=0.8.13-rc make verify-sci-functional-unit
```

The daemon sub-test uses `DAEMON_URL` (default `http://localhost:14318`, the
`make port-forward` endpoint).
