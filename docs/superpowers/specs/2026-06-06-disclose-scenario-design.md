# Design — `disclose` scenario (periodic disclosure two-tier waste, schema v1.1)

## Goal

Wire the v0.8.2 headline feature — periodic disclosure two-tier avoidable
waste — into the lab's standard scenario suite so local `make` runs and the
GitHub release-validation workflow exercise it automatically, instead of the
manual coverage used during the v0.8.2 release-gate validation.

## Approach (decided)

Hermetic **fixtures-based CLI scenario**, same family as
`scenarios/intent-validator/` and `scenarios/verify-hash-roundtrip/`:
`docker run ghcr.io/robintra/perf-sentinel:${PERF_SENTINEL_VERSION:-0.8.2}
disclose` over committed NDJSON fixtures, no cluster/daemon contact,
deterministic, portable to GitHub CI. (Live archiving from a running daemon
was considered and rejected: cluster + k3d-hostPath dependency, non-deterministic
energy values, doesn't match the CLI-scenario family. Adding `[daemon.archive]`
to the committed manifest is a separate, out-of-scope decision.)

## Files — `scenarios/disclose/`

- `verify.sh` (executable), `README.md`
- `fixtures/reports-thr5.ndjson` — compact real v0.8.2-daemon per-window archive
  (operator `n_plus_one_min_occurrences = 5`, canonical threshold 2), curated
  from the v0.8.2 validation run to a small set of non-zero-avoidable,
  runtime-calibrated (`scaphandre_rapl`) windows in the period, covering the 3
  Java services.
- `fixtures/reports-thr50.ndjson` — same workload, operator threshold 50,
  canonical 2 (n+1 reclassified to redundant at the high operator threshold).
- `fixtures/org-config.toml` — complete org-config for `intent=official`:
  `organisation.{name,country}`, 4 core patterns, `conformance=core-required`,
  `carbon_intensity_source=electricity_maps`,
  `specpower_table_version="2026-04-24"` (the 0.8.2 binary's embedded CCF
  vintage — must track the pinned image).

## Sub-tests (`verify.sh`)

Period: `--period-type calendar-quarter --from 2026-04-01 --to 2026-06-30`
(>= 30 days for official; covers the June fixture window timestamps).
JSON assertions via `python3` (consistent with `validate-findings`/`smoke`).

1. **Schema + tiers** (internal/internal over `reports-thr5`):
   `schema_version == "perf-sentinel-report/v1.1"`;
   `aggregate.canonical_waste.n_plus_one_threshold == 2`;
   `aggregate.operational_waste.n_plus_one_threshold == 5`;
   both tiers `energy_kwh > 0` and `carbon_kgco2eq > 0`.
2. **Flat-field aliasing** (same report):
   `estimated_optimization_potential_kgco2eq == canonical_waste.carbon_kgco2eq`;
   `aggregate_waste_ratio == canonical_waste.waste_ratio`;
   `aggregate_efficiency_score == canonical_waste.efficiency_score`.
3. **Official intent + verify-hash round-trip** (official/public over `reports-thr5`):
   `disclose` exits 0 (validator passes); `verify-hash --report <out>
   --no-identity-check` reports content_hash **OK** (the disclose→verify
   round-trip that v0.8.2 fixed via serde_json `float_roundtrip` — the gap
   `verify-hash-roundtrip` could not close). Negative sub-check: a tampered
   copy yields content_hash **FAIL** / UNTRUSTED.
4. **Anti-gaming invariant** (over `reports-thr50`):
   `canonical_waste.n_plus_one_threshold == 2` (UNCHANGED vs `reports-thr5` —
   the operator cannot configure the canonical tier) while
   `operational_waste.n_plus_one_threshold == 50`, and
   `canonical_waste.waste_ratio > operational_waste.waste_ratio` (the operator's
   high threshold under-reports avoidable waste in the operational tier; the
   canonical headline figure is immune). Fixture curation verified empirically
   to make the strict inequality hold.

Aggregate verdict → `/tmp/scenario-disclose-report.md`; exit 0 (all PASS) / 1.

## Wiring

- `Makefile`: `verify-disclose` target → `./scenarios/disclose/verify.sh`; add
  to `.PHONY`; add `bash -n scenarios/disclose/verify.sh` to `make validate`;
  add `disclose` to the `verify-all-scenarios` loop in the CLI group (next to
  `intent-validator` / `verify-hash-roundtrip`); bump the scenario count
  25 → **26** in the `verify-all-scenarios` comment + help text.
- `docs/SCENARIOS.md`: bump "ships 25 scenarios" → 26.

## Out of scope

- `[daemon.archive]` in the committed manifest / a live archiving path.
- Bumping the contract-lock `PERF_SENTINEL_VERSION` pins of other scenarios.
- Cosign-signed `TRUSTED` verify-hash (requires an OIDC ceremony).
