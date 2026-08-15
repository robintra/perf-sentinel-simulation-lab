# export-snapshot-scope

What one `/api/export/report` snapshot actually covers, and what a client does
when it cannot read one. Gates the 0.13.1 export surfaces: the configurable
`max_export_findings` cap, the `snapshot_scope` disclosure, and
`FetchError::BodyTooLarge`.

## Why it exists

The daemon Report an operator pulls is a **slice**, not the store. Findings are
capped, the green figures describe the latest analyzed batch, and the exported
`quality_gate` counts only what the slice carries. A reader who takes the
payload for the daemon's lifetime gets the carbon figures wrong by orders of
magnitude and the verdict wrong outright.

Before this scenario, nothing in the lab checked any of it.
`hybrid-daemon-batch` fetches `/api/export/report`, counts the findings and
renders the HTML. It would stay green if `snapshot_scope` disappeared or
the cap were ignored. `query-monitor-api` checks `/api/config` with an
inclusion list, which by construction only reports keys that are *missing*,
so `max_export_findings` and `max_retained_traces` were both exposed and
unchecked until the same round added them.

## Legs

| leg | asserts |
|---|---|
| `B3-cold` | the cold-start envelope carries `cold_start` and **no** `snapshot_scope`: it describes nothing yet. Deliberate upstream, pinned by no product test |
| `B1-batch-entry` | store fits inside the cap → exactly one `snapshot_scope` entry, the green-figures one |
| `A3-baseline` | the same traces at the default cap → `quality_gate.passed=false` (3 critical N+1 against `n_plus_one_sql_critical_max = 0`) |
| `A1-config` | `/api/config` reports the value passed to `watch --max-export-findings`, not the file's, and exposes `max_retained_traces` |
| `A2-truncates` | cap 2 over a store of 3 → exactly 2 findings exported |
| `B2-truncation-entry` | the truncation entry appears, names **both** counts (`capped at 2 of 3 retained`) and warns that the gate counts only these |
| `A3-zero-cap-counts` | cap 0 → 0 findings, and `n_plus_one_sql_critical_max` goes from `actual=3, passed=false` to `actual=0, passed=true` over an unchanged store |
| `A3-ratio-survives` | `io_waste_ratio_max` still reads the batch value at cap 0, so the whole verdict does **not** unconditionally flip (see Notes) |
| `C1-oversize-named` | a 9 MiB body → `query monitor` shows `[STALE]` **and** `over the 8 MB read limit: lower max_export_findings ...` |
| `C1-control` | the live daemon's normal-sized body is not reported as oversized |
| `C2-inspect-gap` | `query inspect` still flattens the same overrun into an empty view. Recorded `KNOWN`, and flips to `CHANGED` if a later release fixes it |
| `T-pair-warns` | `max_export_findings = 2000` with `max_retained_traces = 400` projects ~10 MB and the startup advisory names both knobs and values |
| `T-traces-clamped` | `max_retained_traces = 100000` **alone** stays silent: the span-tree term is clamped to the byte budget `traces_store::snapshot_for` already enforces |

## Prerequisites

Self-contained. No cluster, no Docker.

- local release binary (`cargo build --release --workspace` in the product
  checkout), `PERF_SENTINEL_LOCAL_BIN` to override
- `jq`, `python3`

Ports 14626 (HTTP), 14627 (gRPC) and 14628 (oversize stub) must be free.
Override with `DAEMON_HTTP_PORT`, `DAEMON_GRPC_PORT`, `STUB_PORT`.

## Run

```bash
make verify-export-snapshot-scope
# against another build:
PERF_SENTINEL_LOCAL_BIN=/path/to/perf-sentinel ./scenarios/export-snapshot-scope/verify.sh
```

## Notes

**The cap-0 trap is real, but narrower than the product says.** CHANGELOG
and `docs/CONFIGURATION.md` state that at `0` the gate's "verdict then
passes whatever the daemon detected", and conclude `0` suits a liveness
probe. Measured here, the three **count** rules do read `actual=0` and
pass, which is the dangerous half. However, `io_waste_ratio_max` comes from
the green summary, which no cap empties, and still failed the gate on the
same traces (`actual=0.917` against a `0.3` threshold). `docs/QUERY-API.md`
describes this split correctly. The legs pin the split rather than the
claim, so a reader of this scenario is not taught something the code
contradicts.

**Why a pty.** `query monitor` is a TUI, without a terminal it draws
nothing at all. `script(1)` needs a tty on its own stdin, which a CI runner
does not have, so the scenario opens one with `pty.openpty()` and forces a
200-column window. The reason is budgeted to 96 characters and a narrow
terminal would cut it.

**Why the stub body need not be a valid Report.** The client refuses the read
past its cap before parsing, so only the size matters. The well-formed-body
control is the live daemon, which is a stronger control than a second stub.
