# semconv-drift

OTel's semantic-convention migration renamed the attribute keys
perf-sentinel's detectors read: `db.statement` → `db.query.text`,
`db.system` → `db.system.name`, `http.method` → `http.request.method`,
`http.url` → `url.full`. During the transition real fleets emit any mix of
the two generations, sometimes both on the same span
(`OTEL_SEMCONV_STABILITY_OPT_IN=http/dup,database/dup`). The product ingest is dual-keyed
across OTLP/Jaeger/Zipkin with a documented preference per pair - but the
lab never isolated the stable-only shape: the astronomy capture dual-emits
per service, every lab generator uses the legacy keys, and `datadog-bridge`
isolates `db.system.name` but still pairs it with `db.statement`. A span
carrying `db.query.text` without `db.statement` had **zero scenario
coverage**. This scenario locks the fallback in both directions: legacy
spans keep working forever, stable-only spans work today.

## What it asserts

| id    | assertion                                                                                                                                                                                     |
|-------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| B0    | die-guard: the untransformed degraded slice analyzes with `traces_analyzed > 0` (a broken baseline is infra, not a semconv finding), and the fixture carries no `db.type` third legacy alias |
| G1-G3 | die-guards: each variant actually carries the intended key population (new-only: zero legacy keys; old-only: zero stable keys; dup: equal counts per pair) - no vacuous equality             |
| D1    | `old-only` variant: `traces_analyzed` and per-class finding counts strictly equal to baseline                                                                                                  |
| D2    | `new-only` variant: same strict equality - **the headline**: the pure-stable corpus shape the lab never fed before                                                                             |
| D3    | `dup` variant (both keys on every carrying span): same strict equality                                                                                                                         |

## How it works

Transform-based replay over the committed astronomy-shop degraded slice -
nothing committed, no cluster, no Docker:

- `drift.py` streams the NDJSON (curate.py's re-emit pattern) and rewrites
  span-level attributes per its `PAIRS` table into three run-time variants
  under `/tmp/semconv-drift/`. Structure, ids and timings are untouched, so
  the trace population is exactly the baseline's.
- The resolved value is always the **preferred** key's - the one ingest
  reads first. The preference is mixed on purpose: `db.system.name` is
  new-preferred (`otlp/mod.rs:225-230`) while the other three pairs are
  old-preferred (`otlp/mod.rs:567-586`). A hardcoded "old wins" would
  be subtly wrong on a dual-keyed span. On the current capture this is
  moot (measured: zero spans carry both keys of any pair - dual
  emission is per service), but the rule makes the equality assertion
  recapture-proof.
- Strict per-class count equality is safe to assert because the rewrite is
  value-preserving by construction and the replay is deterministic: if it
  ever fails, that is precisely the ingest asymmetry this scenario exists
  to catch. `events_processed` is recorded per variant to localize a
  failure to ingest vs detection.
- Scope: span-level attributes only - ingest does not read these keys at
  resource/scope level, so drift.py leaves those untouched.

## Run

```sh
make verify-semconv-drift   # local release binary + python3 only
```

Requires the astronomy-shop fixtures (committed) and the local release
binary (`cargo build --release` in the perf-sentinel checkout).
Report: `/tmp/scenario-semconv-drift-report.md`.
