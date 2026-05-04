# scaphandre-mock-validation

End-to-end validation of the perf-sentinel daemon Scaphandre scrape
path against a Python stdlib mock deployed at
`manifests/scaphandre-mock.yaml`.

## Purpose

Scaphandre reads RAPL counters that are not accessible on Apple
Silicon (registers are Intel-only) nor on most cloud runners (no RAPL
passthrough). Without a mock, the lab cannot exercise the daemon's
`[green.scaphandre]` configuration block, the scraper task spawned at
startup, the parser that ingests `scaph_process_power_consumption_microwatts`,
nor the proxy-model fallback when the exporter is unreachable.

This scenario validates all four legs end-to-end. The mock exposes
exactly the metric perf-sentinel consumes (`parser.rs:39` upstream),
with deterministic per-process power values hashed from `(exe, pid)`.

## Prerequisites

- Cluster bootstrapped: `make up-cni`. The daemon ConfigMap at
  `manifests/perf-sentinel-daemon.yaml` already includes the
  `[green.scaphandre]` block pointing at
  `http://scaphandre-mock:9100/metrics`.
- Mock deployed: `make seed-scaphandre-mock`. The script applies the
  manifest and waits for the Deployment rollout.
- Daemon port-forward live: `./scripts/port-forward.sh start`.

The scenario opens its own ephemeral port-forward to the mock on
`MOCK_LOCAL_PORT` (default 19100) so it does not collide with any
prior `kubectl port-forward` on 9100.

## What is verified

6 sub-tests, each emitting one PASS/FAIL verdict.

1. Sanity: daemon `/api/status` reachable and at least one
   `scaphandre-mock` pod in `Running` phase. Fails fast with an
   actionable hint when the mock is not seeded.
2. Mock `/metrics` shape: 5 `scaph_process_power_consumption_microwatts`
   gauge lines with the required `# HELP` and `# TYPE` directives.
3. Determinism: two consecutive scrapes return identical power
   values. Confirms the SHA-256 hash is stable.
4. Daemon log signal: `"Scaphandre scraper started"` (info-level)
   present in the last 500 daemon log lines, proving the
   `[green.scaphandre]` config was loaded and the scraper task
   spawned. `"Scaphandre scrape failed"` lines are tolerated as a
   soft warning (the mock may have come up after the daemon).
5. Daemon gauge signal: `perf_sentinel_scaphandre_last_scrape_age_seconds`
   sampled twice, `SCRAPE_INTERVAL_SEC + 1` seconds apart. At least
   one sample must be below `SCRAPE_INTERVAL_SEC + 2` seconds (the
   gauge resets to 0 on each successful scrape and grows in real
   time between scrapes). Fails when both samples drift above the
   interval (scraper hung) or when the gauge is absent (build
   without the Scaphandre module).
6. Mock degradation: `kubectl scale deployment/scaphandre-mock
   --replicas=0`, sleep `DEGRADE_WAIT_SEC`, assert daemon
   `/api/status` still answers and `"Scaphandre scrape failed"`
   appears in the recent log tail (proof the daemon registered the
   outage and is now on the proxy-model fallback). The trap restores
   `--replicas=1` on exit, even on interruption.

## How to run

```bash
make verify-scaphandre-mock-validation

# Tunables:
SCRAPE_INTERVAL_SEC=5 DEGRADE_WAIT_SEC=30 MOCK_LOCAL_PORT=19100 \
  ./scenarios/scaphandre-mock-validation/verify.sh

# Inspect the mock /metrics output independently:
kubectl -n observability port-forward svc/scaphandre-mock 9100:9100 &
PF=$!; sleep 2
curl -fsS http://localhost:9100/metrics
kill $PF

# Confirm the daemon picked up the Scaphandre scraper:
kubectl -n observability logs deploy/perf-sentinel-daemon \
  | grep 'Scaphandre scraper started'
# Expected: "Scaphandre scraper started endpoint=... scrape_interval_secs=5
#            process_count=5"
```

The report lands at
`/tmp/scenario-scaphandre-mock-validation-report.md` with the gauge
samples, per-step PASS/FAIL breakdown, and a daemon log tail on FAIL.

## Failure modes covered

- **TOML config regression**: a typo in `[green.scaphandre]` keeps the
  scraper from spawning, sub-test 4 catches the missing log line.
- **Mock format regression**: missing label `exe` or different metric
  name silently skips the line in the upstream parser, sub-test 2
  asserts the format the parser expects.
- **Scraper hung**: the gauge stops resetting to 0, sub-test 5 catches
  it within `2 * SCRAPE_INTERVAL_SEC` seconds.
- **Mock outage = daemon crash**: the daemon must keep `/api/status`
  answering when the exporter is unreachable. Sub-test 6 enforces the
  fallback contract.

## Notes on RAPL absence on Apple Silicon

The lab targets Apple Silicon developers and Linux GHA runners. RAPL
is available on neither (M-series chips have no RAPL registers, and
GHA runners run inside VMs without RAPL passthrough). Running real
Scaphandre would either fail to install (no kernel module) or report
zero per-process power across the board. The mock keeps the scrape
path exercised in CI and locally without needing a Linux bare-metal
host with Intel/AMD RAPL.

When validating on bare-metal Intel/AMD with real Scaphandre running,
swap `endpoint` in the daemon ConfigMap to point at the real exporter
and skip `make seed-scaphandre-mock`. This scenario stays useful as a
regression smoke for the lab manifest path.

## Local vs CI runtime

Total runtime ~50 seconds:

- Sub-tests 1-4 are quick (~5s).
- Sub-test 5 sleeps `2 * (SCRAPE_INTERVAL_SEC + 1)` = ~12s.
- Sub-test 6 sleeps `DEGRADE_WAIT_SEC` (default 30s) plus the
  rollback rollout (~5-10s).

`timeout-minutes: 4` in CI covers worst case plus a margin.
