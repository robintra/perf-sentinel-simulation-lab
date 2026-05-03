# multi-agent-load

Validate the perf-sentinel daemon under concurrent OTLP load. A single
production daemon ingests traces from N parallel producers running
`telemetrygen` inside the cluster.

## Use case

When many services (or many replicas of one service) push OTLP traces to
the same daemon, the daemon must:

- accept OTLP requests without dropping the TCP connection,
- backpressure cleanly if saturated (visible as a deficit in
  `events_processed` rather than crashes or panics),
- emit findings without losing data,
- keep memory bounded.

This scenario exercises (1)-(4) by spawning a kubectl Job with
`parallelism=PRODUCERS` of `telemetrygen` Pods, each emitting OTLP HTTP
traces at `RATE_PER_PRODUCER` spans/sec for `DURATION`. The Pods target
the production daemon Service via cluster DNS, so the test reproduces a
realistic in-cluster client topology.

## Architecture

```
+--------------------+        OTLP HTTP        +-------------------------+
| b3-multi-agent ns  |  ---->                  |  observability ns        |
|  Job parallelism=N |        14318            |  perf-sentinel-daemon    |
|  telemetrygen pods |                         |  Service ClusterIP       |
+--------------------+                         +-------------------------+
                                                          |
                                                          | /api/export/report
                                                          v
                                              verify.sh asserts on:
                                              - events_processed delta
                                              - active_traces (post-drain)
                                              - process_resident_memory_bytes
                                              - /api/status liveness
```

## Inputs

| Variable             | Default | Notes                                          |
| -------------------- | ------- | ---------------------------------------------- |
| `PRODUCERS`          | 10      | Job parallelism. CI smoke uses 10, local stress 50-200. |
| `RATE_PER_PRODUCER`  | 100     | spans/sec per pod                               |
| `DURATION`           | 60s     | telemetrygen `--duration`                       |
| `RSS_LIMIT_BYTES`    | 524288000 (500 MiB) | Verdict threshold on daemon RSS  |
| `KEEP_NAMESPACE`     | no      | Set to `yes` to inspect Pods after the run      |

## Verdict

PASS when all three hold post-drain:

- daemon `/api/status` still answers,
- `events_processed` delta >= 50 % of `PRODUCERS * RATE * DURATION`
  (some backpressure is acceptable, catastrophic loss is not),
- `process_resident_memory_bytes` < `RSS_LIMIT_BYTES`.

FAIL surfaces daemon log tail in the report.

## Local stress vs CI smoke

CI runs the smoke profile (`PRODUCERS=10`) inside a 45-min job. Local
stress is opt-in: `PRODUCERS=50 make verify-multi-agent-load` for a
moderate run, or `PRODUCERS=200` to approach the k3d single-node ceiling.
1000 concurrent Pods exceeds Docker Desktop k3d capacity in practice.

## Runtime prerequisites

- Lab bootstrap done: `make up-cni && make seed-services`.
- Daemon port-forward live: `./scripts/port-forward.sh start`.
- The cluster zero-trust NetworkPolicy is honored: this scenario ships
  its own egress + ingress allow-rules scoped to `b3-multi-agent`.
