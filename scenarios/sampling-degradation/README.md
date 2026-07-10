# sampling-degradation

Production almost never delivers the corpus the lab feeds perf-sentinel:
real deployments sample (head-based or tail-based) and collectors drop spans
under pressure, so the analyzer sees **partial call graphs**. The lab's own
services run `always_on`, and the product has no upstream-sampling awareness
by design (its `sampling_rate` config is the daemon's *own* ingest
down-sampler, `daemon/sampling.rs` - not compensation for sampling done
upstream). This scenario locks the next-best contract: perf-sentinel must
**degrade properly** on sampled input - never crash, lose findings
monotonically rather than erratically, never invent a finding class from
truncated fragments, and never push a clean corpus over its false-positive
budget.

## What it asserts

| id | assertion                                                                                                                                                                                            |
|----|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| S0 | die-guard (not an assertion): transforms actually degrade - keep counts strictly decreasing across rates, span-loss drops > 0. A no-op transform aborts the run instead of vacuously passing it      |
| A1 | all 8 variants: `analyze --input` exit 0 + parseable JSON, even on a ~2-trace corpus (1% keep) or broken parent chains                                                                                 |
| A2 | degraded slice, trace-sampled at 100/50/10/1% keep: total findings monotone non-increasing. Total only - per-class monotonicity would flake on legitimate reclassification as spans vanish            |
| A3 | every degraded variant: finding classes are a subset of the in-run degraded baseline (no class invented). Manifest intersection recorded per variant for recall visibility, not asserted              |
| A4 | clean slice, trace-sampled at 50/10/1%: total findings `<= fp_budget` from the astronomy-shop manifest - sampling must never create false positives                                                   |
| A5 | degraded span-loss variant: `traces_analyzed > 0` (finding counts unconstrained by design)                                                                                                             |
| A6 | clean span-loss variant: classes subset of the in-run clean baseline; count vs budget recorded informationally (broken parentage may legitimately reshape timing statistics, so no budget assertion) |

## How it works

Transform-based replay over the committed astronomy-shop fixtures - nothing
new is committed, no cluster, no Docker:

- `degrade.py` streams the NDJSON slices (curate.py's re-emit pattern, every
  output line stays a valid `ExportTraceServiceRequest`) and produces 8
  variants under `/tmp/sampling-degradation/` at run time:
  - **trace-sample** keeps a span iff `fnv1a64(traceId)/2^64 < keep-rate`,
    a byte-for-byte port of the product's own `daemon/sampling.rs` hash
    (self-checked at import). Whole-trace consistency is automatic and
    keep-sets are **nested across rates** (same hash, threshold compare) -
    which is what makes A2's monotone assertion structurally sound, down to
    the ~2-trace 1% corpus.
  - **span-loss** keeps every root span and drops non-root spans iff
    `fnv1a64(traceId + spanId)/2^64 < drop-rate` (spanId salt = independent,
    deterministic per-span decisions): collector loss with broken parentage.
- Baselines (untransformed slices) are analyzed in-run, never hardcoded, so
  every assertion is relational - chains, subsets, and the manifest's
  `fp_budget` - and nothing needs restamping when the binary evolves.
- A2/A4 knowingly assert detector monotonicity under a nested trace subset:
  a violation is exactly the "does not degrade properly" signal this scenario
  hunts, and replay determinism makes it a stable failure to triage, never a
  flake.

## Run

```sh
make verify-sampling-degradation   # local release binary + python3 only
```

Requires the astronomy-shop fixtures (committed) and the local release
binary (`cargo build --release` in the perf-sentinel checkout).
Report: `/tmp/scenario-sampling-degradation-report.md`.
