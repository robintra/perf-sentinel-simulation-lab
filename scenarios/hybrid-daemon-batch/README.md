# hybrid daemon to batch HTML

## Use case

A daemon runs in production and accumulates findings via its rolling
window correlator. A developer or CI job snapshots the daemon's
`/api/export/report` endpoint and renders a single-file HTML dashboard
for shareable post-mortem. No re-analysis is run on the snapshot.

## Run

```bash
make verify-hybrid-daemon-batch
```

## What is verified

The daemon Report JSON is fed to `perf-sentinel report --input` and
produces a self-contained HTML file (>10 KB). The output preserves
the daemon's findings and correlations exactly.

## Limitations

The CLI does not support `analyze --format sarif` on a Report JSON
(`analyze` expects raw trace events, not pre-computed Reports). The
SARIF-from-batch path lives in the batch-tempo-scrape scenario.
Cross-trace correlations are computed daemon-side only and are not
recreated by batch analyze.

## Output

`/tmp/scenario-hybrid-daemon-batch-report.md` plus the HTML
dashboard at `/tmp/hybrid-daemon-batch/dashboard.html`.

## Which binary this runs against

`scripts/resolve-image.sh` picks the image: `PERF_SENTINEL_IMAGE` (a full
reference, for a locally built pre-release), then `PERF_SENTINEL_VERSION` (a
GHCR tag), then the pin in `manifests/perf-sentinel-daemon.yaml`.

It used to default to a hardcoded old tag, so the scenario ran green on every
release without ever touching the version under validation — the gate reported a
PASS for code it had not executed. The 0.9.25 round is what surfaced that, and
the eight image scenarios now share this resolution.
