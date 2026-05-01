# B2-7 cross-trace correlation finding

## Use case

A system has many services calling each other. The daemon's rolling
window correlator tracks span templates that systematically co-occur
across traces. When `service-A.span-X` consistently leads to
`service-B.span-Y` within the configured lag window, the correlator
exposes the pair via `/api/correlations` with a confidence score.
Operators use this to spot tight cross-service coupling, surface
latency sources, or detect cascade-prone request chains.

## Run

```bash
make verify-b2-7-correlation-finding
```

## What is verified

The verify script runs `make validate-findings` (chatty + fanout +
serialized scenarios produce intentional cross-service call chains),
waits 90 s for the correlator window to populate, then queries
`/api/correlations` on the lab daemon. PASS if the endpoint returns at
least one entry with `confidence > 0.5`.

## Configuration

Daemon `config.toml`:

```toml
[daemon.correlation]
enabled = true
window_minutes = 5
lag_threshold_ms = 60000
min_co_occurrences = 2
min_confidence = 0.5
```

Set in `manifests/perf-sentinel-daemon.yaml` for the lab.

## Output

`/tmp/scenario-b2-7-correlation-finding-report.md` plus the raw
correlation list at `/tmp/b2-7-correlation-finding/correlations.json`.
