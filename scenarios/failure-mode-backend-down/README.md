# failure-mode-backend-down

Validate that the daemon survives a panne of each backend (OTel
collector, Tempo, Postgres). For each sub-test, scale the backend to 0
replicas for `PANNE_DURATION` seconds, then restore. The daemon must
keep `/api/status` answering and emit no panic in its logs.

## Use case

A production setup has many ways one of the backends can fail
independently of the daemon: a node drain, a chart upgrade, a noisy
neighbor evicting the Pod. The daemon's role is to fail soft against
each backend.

| Sub-test                | Expected daemon behaviour                                  |
| ----------------------- | --------------------------------------------------------- |
| OTel collector down     | Daemon up. Daemon receives OTLP directly on 14318, does not depend on the collector for watch mode. Direct producers (telemetrygen, sidecar instrumentation) keep working. |
| Tempo down              | Daemon up. Watch mode never queries Tempo, only batch mode does. Sub-test is conservatoire, validates no implicit dep. |
| Postgres down           | Daemon up. The optional `--pg-stat-prometheus` scrape may log a warning, but ingestion continues. |

## Sequence

For each backend, the script:

1. captures the original `replicas` value,
2. scales the resource to 0,
3. waits `PANNE_DURATION` seconds and probes `/api/status` mid-panne,
4. restores to the original replicas,
5. waits for `rollout status`,
6. probes `/api/status` again,
7. counts the delta of `panic`/`FATAL` lines in `kubectl logs --since=2m`.

The `trap RETURN` ensures the original replicas are restored even if
the script fails mid sub-test.

## Inputs

| Variable             | Default | Notes                                  |
| -------------------- | ------- | -------------------------------------- |
| `PANNE_DURATION`     | 30      | seconds the backend stays at 0 replicas |
| `KEEP_NAMESPACE`     | n/a     | this scenario does not create a namespace |

## Verdict per sub-test

PASS when:

- `/api/status` answers during the panne,
- `/api/status` answers after restore,
- panic/FATAL log delta <= 0.

SKIP when the resource selector matches no resource (e.g. Tempo not
deployed in the current cluster). Surface as info, not failure.

FAIL when any of the three asserts above breaks. Daemon log tail goes
into the report.

The aggregate scenario verdict is FAIL if any sub-test FAIL, PASS if
all three are PASS or SKIP.

## Risk: shared backend impact

Postgres is shared with `order-service` (namespace `shop`). Scaling it
down briefly during a CI run may affect a parallel scenario invocation,
but B3 scenarios run sequentially in the workflow and the
`make verify-all-scenarios` aggregator. Running this scenario in
isolation against a busy lab is the safer mode.

## Runtime prerequisites

- Lab bootstrap done: `make up-cni && make seed-services`.
- Daemon port-forward live: `./scripts/port-forward.sh start`.
