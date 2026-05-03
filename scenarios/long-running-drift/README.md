# long-running-drift

Detect slow leaks (memory, file descriptors, in-flight traces) that are
invisible on short runs. The daemon runs under continuous traffic for
hours, and `verify.sh` samples its `/metrics` endpoint at fixed
intervals, then compares the warm window to the tail window.

## Use case

A leak of 1 MB/h is undetectable on a 5-minute scenario but accumulates
to 24 MB after a day. The lab validates two regimes:

1. Default 2 h at 10x base traffic. Aggressive enough to surface leaks
   that scale with throughput, short enough to fit in a developer's
   afternoon.
2. `LONG_RUN=1`: 24 h at 1x traffic. For genuine production-pace leak
   hunting on the developer machine. Sample interval auto-stretches to
   15 min.

CI runs a 5-minute smoke (just to verify the harness loop, not real
drift detection).

## Architecture

```
+----------------+        OTLP HTTP        +-------------------------+
| b3-drift ns    |  ---->                  |  observability ns        |
|  Job paral=2   |        14318            |  perf-sentinel-daemon    |
|  rate=Nsps     |                         |  (production deployment) |
+----------------+                         +-------------------------+
                                                      |
                                              every SAMPLE_INTERVAL s
                                                      |
                                                      v
                                          verify.sh appends a row to
                                          /tmp/long-running-drift/drift-samples.tsv
                                          (timestamp, rss, fds, active_traces)
```

Drift is computed as the percent change of average RSS between the warm
window `[10-30 %]` of samples and the tail window `[70-100 %]`. The 10 %
prefix is dropped to exclude cold-start effects.

## Inputs

| Variable             | Default | LONG_RUN=1 override | Notes                                  |
| -------------------- | ------- | -------------------- | -------------------------------------- |
| `DURATION_HOURS`     | 2       | 24                   | total run length                       |
| `SAMPLE_INTERVAL`    | 300     | 900                  | seconds between samples                |
| `TRAFFIC_MULTIPLIER` | 10      | 1                    | multiplies the base 100 sps            |
| `DRIFT_PCT_LIMIT`    | 10      | 10                   | RSS drift threshold for PASS           |

## Verdict

PASS when:

- daemon `/api/status` answers at the end of the run,
- absolute RSS drift between warm and tail windows < `DRIFT_PCT_LIMIT %`,
- file descriptor delta < 5,
- `perf_sentinel_active_traces` is not monotonically growing past
  `max(50, warm_average)` (a leak of in-flight traces would otherwise
  inflate this gauge linearly).

FAIL surfaces daemon log tail in the report and points to the TSV.

## Local stress vs CI smoke

CI : `DURATION_HOURS=0.083 SAMPLE_INTERVAL=30` (5 min, 10 samples). Just
verifies the loop does not throw.

Local default : `make verify-long-running-drift` (2h, 24 samples).

Long run : `LONG_RUN=1 make verify-long-running-drift` (24h, ~96
samples). Run in a screen session or under `caffeinate -d` on macOS.

## Runtime prerequisites

- Lab bootstrap done : `make up-cni && make seed-services`.
- Daemon port-forward live : `./scripts/port-forward.sh start`.
