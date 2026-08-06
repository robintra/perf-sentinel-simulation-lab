# multi-agent-load

Validate the perf-sentinel daemon under concurrent OTLP load. A single
production daemon ingests traces from N parallel producers running
`telemetrygen` inside the cluster.

## Use case

When many services (or many replicas of one service) push OTLP traces to
the same daemon, the daemon must:

- accept OTLP requests without dropping the TCP connection,
- expose any backpressure through the OTLP rejection counter,
- convert RPC client spans into analyzable events,
- keep memory bounded.

This scenario exercises (1)-(4) by spawning a kubectl Job with
`parallelism=PRODUCERS` of `telemetrygen` Pods, each emitting OTLP HTTP
traces at `RATE_PER_PRODUCER` spans/sec for `DURATION`. The Pods target
the production daemon Service via cluster DNS, so the test reproduces a
realistic in-cluster client topology. Explicit RPC attributes are required:
plain `telemetrygen` spans do not describe an I/O operation and are correctly
filtered as `not_io`.

## Architecture

```
+--------------------+        OTLP HTTP        +-------------------------+
| multi-agent-load ns  |  ---->                  |  observability ns        |
|  Job parallelism=N |        14318            |  perf-sentinel-daemon    |
|  telemetrygen pods |                         |  Service ClusterIP       |
+--------------------+                         +-------------------------+
                                                          |
                                                          | /api/export/report
                                                          v
                                              verify.sh asserts on:
                                              - raw OTLP received delta
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
| `MIN_EVENTS_DELTA`   | 3       | Minimum analyzable events after the burst       |
| `RSS_LIMIT_BYTES`    | 524288000 (500 MiB) | Verdict threshold on daemon RSS  |
| `KEEP_NAMESPACE`     | no      | Set to `yes` to inspect Pods after the run      |

## Verdict

PASS when all four hold post-drain:

- daemon `/api/status` still answers,
- raw OTLP spans received >= 90% of `PRODUCERS * RATE * DURATION`,
- `events_processed` delta >= `MIN_EVENTS_DELTA`,
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
  its own egress + ingress allow-rules scoped to `multi-agent-load`.
