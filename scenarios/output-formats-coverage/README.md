# Output formats coverage

4 sub-tests that exercise the perf-sentinel CLI surface around findings
emission, baseline diffing, and the security cap on the ack file. Reuses
artefacts produced by the `ci-shift-left` scenario, so always run that
one first.

## Run

```bash
make verify-ci-shift-left          # produces /tmp/ci-shift-left/*.json
make verify-output-formats-coverage

# Override CLI image:
PERF_SENTINEL_VERSION=0.5.17 make verify-output-formats-coverage
```

Report lands at `/tmp/scenario-output-formats-coverage-report.md`.
Wall clock ~30 s on a warm cache.

## Sub-tests

### 6.A. Coverage of 4 formats + signature

The 0.5.17 CLI supports text/json/sarif via `analyze --format`, plus
HTML via the separate `report` subcommand (HTML is not a flag on
analyze). Markdown was probed and is not a supported format in 0.5.17
(memory item 11).

Asserts:
- All 4 outputs are non-empty (HTML > 1 KiB).
- JSON `findings` count == SARIF `runs[0].results` count.
- Every JSON finding has a non-empty `signature` field (0.5.17 feature).
- SARIF signature presence is logged but does NOT fail the scenario:
  the SARIF emitter does not include signature in 0.5.17 (memory item
  10 OPEN, suggested upstream addition: `properties.signature` or
  `fingerprints["perfsentinel/v1"]`).
- Markdown format failure is logged informationally.

### 6.B. Diff mode

Runs `perf-sentinel diff --before baseline --after regression --format
json`. Schema confirmed against `crates/sentinel-core/src/diff.rs:44-56`
(`new_findings`, `resolved_findings`, `severity_changes`,
`endpoint_metric_deltas`).

Asserts:
- All 4 expected fields present in the diff JSON.
- `new_findings | length > 0` (the regression run introduced findings vs
  the clean baseline).

### 6.C. Cap loader

Generates ~17 MiB of valid TOML (above the 16 MiB cap from
`crates/sentinel-core/src/acknowledgments.rs:30`,
`MAX_ACKNOWLEDGMENTS_FILE_BYTES`) and feeds it to `analyze
--acknowledgments`. Asserts:
- `analyze` exits non-zero (rejects the file).
- The error message mentions size / cap (`AcknowledgmentLoadError::TooLarge`
  surfaces a structured message, not a panic).

### 6.D. Sanity gate

Runs `analyze --ci` against the clean baseline as a smoke check on
the CLI plumbing. Logged informationally. On long-lived clusters
the gate may fail on residue findings, which is acceptable.

## Limitations

- Depends on artefacts from `ci-shift-left`. If that scenario was not
  run, this one fails fast with a clear error pointing to it.
- SARIF signature gap and markdown gap are documented in the lab
  memory's perf-sentinel followup as items 10 and 11. The scenario
  re-checks them on every run so the day upstream fixes them, the
  warning flips to "OK, close memory item N".

## Files

| File | Purpose |
| --- | --- |
| `verify.sh` | 4 sub-tests + verdict (~30 s wall clock) |

## Which binary this runs against

`scripts/resolve-image.sh` picks the image: `PERF_SENTINEL_IMAGE` (a full
reference, for a locally built pre-release), then `PERF_SENTINEL_VERSION` (a
GHCR tag), then the pin in `manifests/perf-sentinel-daemon.yaml`.

It used to default to a hardcoded old tag, so the scenario ran
green on every release without ever touching the version under
validation. The gate reported a PASS for code it had not executed.
The 0.9.25 round is what surfaced that, and the eight image
scenarios now share this resolution.
