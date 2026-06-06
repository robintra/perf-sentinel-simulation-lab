# Design — `disclose-temporal` scenario (periodic disclosure v1.2 continuity)

## Goal

Give the lab permanent coverage of the v0.8.3 schema-v1.2 additions, which the
existing `disclose` scenario (a 0.8.2 / schema-v1.1 contract lock) does not test:
`aggregate.temporal_coverage`, `scope_manifest.coverage_basis`, the reserved
`integrity.cross_period_log`, the temporal continuity signal (dense vs sparse),
and the new v1.2 validator rules. Validated manually during the v0.8.3
release-gate run; this makes it a standing scenario for local + GitHub runs.

## Approach

Separate hermetic fixtures-based CLI scenario, same family as `disclose` /
`intent-validator`: `docker run ...:${PERF_SENTINEL_VERSION:-0.8.3} disclose`
over committed NDJSON fixtures, no cluster. Kept separate from `disclose` so the
0.8.2 / v1.1 contract lock stays intact; this one is the 0.8.3 / v1.2 lock.

## Files — `scenarios/disclose-temporal/`

- `verify.sh` (executable), `README.md`
- `fixtures/reports-dense.ndjson` — 30 windows, one per UTC day across a 30-day
  custom period (2026-05-08..2026-06-06), fabricated from a real 0.8.3-daemon
  archive line by varying only `ts` (findings trimmed; tiers/energy live in
  `disclosure_waste` + `green_summary`).
- `fixtures/reports-sparse.ndjson` — 3 windows on days 0/14/29 of the same
  period (2026-05-08, 2026-05-22, 2026-06-06) → largest gap 14.
- `fixtures/org-config.toml` — complete org-config for official intent;
  `specpower_table_version = "2026-04-24"` (0.8.3 binary's embedded CCF vintage),
  no `total_requests_in_period` (the C5-style reject sub-test adds it via `sed`).

## Sub-tests (`verify.sh`)

Period: `--period-type custom --from 2026-05-08 --to 2026-06-06` (30 days, frozen
to match the frozen fixture `ts` values). JSON asserts via `python3`.

1. **schema v1.2 + v1.2 fields** (internal over dense): `schema_version ==
   "perf-sentinel-report/v1.2"`; `aggregate.temporal_coverage` present with all
   four subfields; `scope_manifest.coverage_basis` present
   (`operator_declared` + `machine_derived`); `integrity.cross_period_log` absent.
2. **dense continuity**: `temporal_coverage == 1.0`, `observed_days ==
   days_in_period == 30`, `largest_gap_days == 0`; NO "temporal coverage is"
   warning on stderr; in-band "Temporal coverage" disclaimer present.
3. **sparse continuity**: `temporal_coverage == 0.1` (3/30), `largest_gap_days
   == 14`; stderr warning `temporal coverage is 10.0%`; in-band disclaimer.
4. **verify-hash round-trip** (the 0.8.2 guard, now with the `temporal_coverage`
   float in the canonical hash): content_hash OK on the dense and sparse
   outputs; a tampered copy (mutate `temporal_coverage`) verifies as FAIL.
5. **v1.2 validator reject**: official over dense with an org-config whose
   `total_requests_in_period` is below `requests_measured` → `disclose` exits
   non-zero (`requests_measured ... exceeds ... total_requests_in_period`), no
   file written.

Aggregate verdict → `/tmp/scenario-disclose-temporal-report.md`; exit 0/1.

## Wiring

- `Makefile`: `verify-disclose-temporal` target; `.PHONY`; `bash -n` line in
  `make validate`; add `disclose-temporal` to the `verify-all-scenarios` loop
  (CLI group, after `disclose`); bump the count 26 → **27**.
- `docs/SCENARIOS.md`: bump count to 27.

## Timing caveat

Pinned to 0.8.3, so it runs in CI/local only once the 0.8.3 GHCR image is
published (same as `disclose` pinned to 0.8.2 at its release). Authored and
tested now against the local `perf-sentinel:v0.8.3-rc` image
(`PERF_SENTINEL_VERSION=v0.8.3-rc`).

## Out of scope

Two-tier waste tiers (covered by the `disclose` scenario), live daemon
archiving, and an edited-block validator re-run (no validate-from-file CLI).
