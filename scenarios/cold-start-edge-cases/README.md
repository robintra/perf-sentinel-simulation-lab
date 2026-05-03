# cold-start-edge-cases

4 sub-tests of daemon cold-start corner cases. The happy path is
covered by every other scenario, this one validates the fringes.

## Sub-tests

### 6.A zero-traffic cold-start

After a `kubectl rollout restart`, no traffic flows for 60 seconds.
Asserts:

- `/api/status` answers,
- `/api/export/report` answers and the JSON has a `warnings` key
  (whether or not the value is empty).

### 6.B cold-start + immediate burst

After a `rollout restart`, immediately apply a Job parallelism=5 of
telemetrygen at 200 sps for 30 s. Asserts:

- `/api/status` answers,
- `events_processed` delta > 1000 (5 pods x 200 sps x 30 s = 30000
  expected; we use 1000 as a tolerant lower bound to account for
  cold-pool sampling and ramp-up).

### 6.C malformed TOML config (must fail-fast)

`docker run --rm` of the daemon image with a volume-mounted TOML file
that contains intentional syntax errors. Asserts:

- daemon exits non-zero within 15 seconds,
- stderr contains at least one of `invalid`, `parse`, `syntax`,
  `expected`, `TOML`.

The image is the same one currently deployed (read via `kubectl get
deployment -o jsonpath`) so the test honors any GHA image-patching done
upstream.

### 6.D cold-start without the Electricity Maps secret

Backs up `secrets/perf-sentinel-electricity-maps`, deletes it,
`rollout restart`, waits 30 s. Asserts:

- daemon `/api/status` answers (no crash on missing token),
- `/api/export/report` answers (no panic on the GreenOps code path).

The secret is restored at the end (idempotent kubectl apply of the
backup YAML), and a final rollout brings the daemon back to its
original token-equipped state.

## Inputs

No tunable env vars; the script paces itself through the 4 sub-tests
sequentially. Total wall clock 8-12 minutes depending on rollout
latency on the runner.

## Aggregate verdict

PASS if all sub-tests PASS or SKIP. FAIL if any sub-test FAIL.

SKIP outcomes:

- 6.C: SKIP if the daemon image cannot be read (RBAC issue).
- 6.D: SKIP if the EM secret is not provisioned (run
  `make seed-electricity-maps` first).

## Cleanup

- The scenario namespace `b3-cold-start` is deleted on exit.
- The reciprocal NetworkPolicy in `observability` is deleted on exit.
- The EM secret backup is reapplied on exit, even if the script fails
  mid-run (trap on EXIT).

## Runtime prerequisites

- Lab bootstrap done: `make up-cni && make seed-services`.
- Daemon port-forward live: `./scripts/port-forward.sh start`.
- For 6.D: `make seed-electricity-maps` already run at least once.
- Docker installed locally (for 6.C).
