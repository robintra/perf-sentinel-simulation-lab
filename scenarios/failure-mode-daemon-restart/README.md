# failure-mode-daemon-restart

Validate that the daemon survives a `kubectl rollout restart` while
OTLP traffic is in flight: spans during the restart window may be lost
gracefully, but the daemon must come back, accept new traffic, and not
panic.

> **0.8.5 update.** A graceful `SIGTERM` (rolling update, scale-down, node
> drain) now **drains** the in-flight streaming window through detection, so
> the "may be lost (graceful drop)" wording below applies specifically to an
> ungraceful `SIGKILL` / over-grace-period kill. The drain itself is proven by
> [`daemon-sigterm-drain`](../daemon-sigterm-drain/); this scenario keeps its
> narrower contract (recovery, no panic, ingestion resumes) which holds on
> every version.

## Use case

Daemon redeploys are routine (image bump, config change, node drain).
The Job emits analyzable RPC spans. The contract is: traffic is active before
the rollout, in-flight spans may be dropped, but the daemon must recover
automatically without manual intervention, and the post-restart counter must
climb again.

## Sequence

```
T+0    apply traffic Job (telemetrygen --rate=50 --duration=180s)
T+60   snapshot events_pre via /api/export/report
T+60+  kubectl rollout restart deployment/perf-sentinel-daemon
       kubectl rollout status (timeout 120s)
       pkill stale port-forward, ./scripts/port-forward.sh start
       poll /api/status until reachable
T+60+r+60   snapshot events_post
       scan daemon logs --since=5m for panic/FATAL
```

## Inputs

| Variable             | Default | Notes                                  |
| -------------------- | ------- | -------------------------------------- |
| `PRE_RESTART_WAIT`   | 60      | seconds of nominal traffic pre-restart |
| `POST_RESTART_WAIT`  | 60      | seconds for post-restart ingestion to flow |
| `TRAFFIC_DURATION`   | 180s    | total telemetrygen run window          |
| `TRAFFIC_RATE`       | 50      | spans/sec from the single producer Pod |

## Verdict

PASS when:

- daemon `/api/status` answers post-restart,
- `events_processed` increases before the restart (traffic is in flight),
- `events_processed` > 0 in the post-restart snapshot (ingestion resumed),
- no `panic` / `FATAL` lines in `kubectl logs --since=5m`.

FAIL writes the daemon log tail into the report.

## Risk: port-forward zombie

The pre-restart port-forward survives the rollout but holds a stale TCP
endpoint. The script kills it explicitly via `pkill` and re-spawns a
fresh one through `scripts/port-forward.sh start` before the post-restart
poll. This mirrors what `validate-on-release.yml` does between scenario
steps.

## Runtime prerequisites

- Lab bootstrap done : `make up-cni && make seed-services`.
- Daemon port-forward live : `./scripts/port-forward.sh start`.
