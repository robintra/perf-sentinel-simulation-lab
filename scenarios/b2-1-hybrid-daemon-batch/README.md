# B2-1 hybrid daemon to batch HTML

## Use case

A daemon runs in production and accumulates findings via its rolling
window correlator. A developer or CI job snapshots the daemon's
`/api/export/report` endpoint and renders a single-file HTML dashboard
for shareable post-mortem. No re-analysis is run on the snapshot.

## Run

```bash
make verify-b2-1-hybrid-daemon-batch
```

## What is verified

The daemon Report JSON is fed to `perf-sentinel report --input` and
produces a self-contained HTML file (>10 KB). The output preserves
the daemon's findings and correlations exactly.

## Limitations

The CLI does not support `analyze --format sarif` on a Report JSON
(`analyze` expects raw trace events, not pre-computed Reports). The
SARIF-from-batch path lives in scenario B2-2 (batch over Tempo).
Cross-trace correlations are computed daemon-side only and are not
recreated by batch analyze.

## Output

`/tmp/scenario-b2-1-hybrid-daemon-batch-report.md` plus the HTML
dashboard at `/tmp/b2-1-hybrid-daemon-batch/dashboard.html`.
