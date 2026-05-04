# daemon-ack-workflow

End-to-end validation of the perf-sentinel daemon ack workflow. Validates
the 0.5.20 ack API (POST/DELETE/GET) with the 0.5.21 Prometheus counter
surface, plus persistence on the `perf-sentinel-acks` PVC across daemon
restarts.

## Purpose

The 0.5.20 daemon exposes an ack API that lets operators acknowledge
findings (e.g. "sig X is a known-deferred bug, hide it from the default
report"). Acks are persisted on disk as JSONL and compacted at startup.
The 0.5.21 release adds a Prometheus counter surface with pre-warmed
series so dashboards never go blank.

This scenario validates that the lab manifest wires the PVC correctly,
the ack API behaves as documented, persistence survives a rollout, and
the counter pre-warming + delta semantics hold.

## Prerequisites

- Cluster bootstrapped with a perf-sentinel daemon at 0.5.20 or later.
  The lab manifest at `manifests/perf-sentinel-daemon.yaml` is the
  reference: it mounts the `perf-sentinel-acks` PVC at
  `/var/lib/perf-sentinel/` and enables `[daemon.ack]` in the ConfigMap.
- At least 3 distinct finding signatures present in the daemon (the
  scenario harvests `sig_a`, `sig_b`, `sig_c` separately). Run `make
  seed-services && scripts/validate-findings.sh` before this scenario,
  or chain it after another scenario that seeds findings.
- Daemon port-forward up on the conventional `DAEMON_LOCAL_PORT`
  (default 14318). The scenario refreshes the port-forward itself
  around the rollout step.

## What is verified

1. Daemon reachable on `/api/status`.
2. At least 3 distinct finding signatures available via
   `/api/export/report` (harvested as `sig_a`, `sig_b`, `sig_c`).
3. Idempotent cleanup: best-effort `DELETE` on each harvested
   signature so a re-run on a daemon with persisted acks starts from
   a clean slate. Counter snapshot baseline taken right after.
4. `POST /api/findings/<sig_a>/ack` with a long TTL, returns 201
   Created.
5. Filter behavior: feature-detect `/api/findings`, soft-assert that
   `?include_acked=true` exposes `acknowledged_by.by`.
6. Counter delta `ack_operations_total{action="ack"} += 1` after the
   POST. Falls back to `GET /api/acks` lookup when the counter
   surface is absent (0.5.20 daemon without 0.5.21 pre-warming).
7. `kubectl rollout restart` then verify `sig_a` survives via the
   PVC-backed JSONL store.
8. Second `POST /api/findings/<sig_b>/ack` with a long TTL,
   returns 201.
9. Conflict path: re-POSTing `sig_b` returns 409 and increments
   `ack_operations_failed_total{action="ack",reason="already_acked"}`.
10. `DELETE /api/findings/<sig_b>/ack` returns 204 No Content and
    increments the `unack` counter.
11. TTL filter: `POST /api/findings/<sig_c>/ack` with a short TTL,
    sleep past the deadline, poll `GET /api/acks` and confirm
    `sig_c` is no longer surfaced (query-time filtering).

## How to run

```bash
make verify-daemon-ack-workflow

# Tunables (env vars):
TTL_SEC=30 TTL_LONG_SEC=300 EXPIRY_SLEEP_SEC=35 EXPIRY_POLL_SEC=15 \
  ./scenarios/daemon-ack-workflow/verify.sh

# Inspect the JSONL after the run. The daemon image is distroless
# (FROM scratch), so the standard `kubectl exec ... cat` does not work.
# Use kubectl debug with an ephemeral container that has shell tools:
DAEMON_POD=$(kubectl -n observability get pod \
  -l app.kubernetes.io/name=perf-sentinel-daemon \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n observability debug "${DAEMON_POD}" --target=perf-sentinel \
  --image=busybox:1.37 --quiet -- \
  cat /var/lib/perf-sentinel/acks.jsonl
```

The report lands at `/tmp/scenario-daemon-ack-workflow-report.md` with
counter source (`counter_present_0521` or `counter_absent_0520_fallback`)
and a per-step PASS/FAIL breakdown.

## Failure modes covered

- **API regression**: a POST/DELETE returning the wrong status code
  fails the scenario rather than silently passing.
- **PVC misconfiguration**: if the JSONL store is not mapped to a
  persistent volume, the rollout-restart step fails because the ack
  vanishes.
- **Counter regression**: a missing pre-warmed series in 0.5.21 is
  still PASS via the API fallback, but the verdict source changes to
  `counter_absent_0520_fallback` so the regression is visible in the
  report.
- **TTL filter regression**: if the daemon does not filter expired
  entries at query time, step 11 catches it within
  `EXPIRY_SLEEP_SEC + EXPIRY_POLL_SEC` seconds.

## Local stress vs CI smoke

Total runtime is ~4-5 minutes locally:

- Sub-tests 1-6 are quick (~30s).
- Step 7 (rollout) takes ~60-90s with the `Recreate` strategy.
- Step 11 sleeps `EXPIRY_SLEEP_SEC` (default 35s) plus up to
  `EXPIRY_POLL_SEC` (default 15s).

In CI the scenario runs with the default profile after `make
seed-services && scripts/validate-findings.sh` has populated the
findings store. `timeout-minutes: 6` covers the worst case plus a
margin.
