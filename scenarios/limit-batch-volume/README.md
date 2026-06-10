# limit-batch-volume

Large-input batch CLI validation, no cluster needed. tracegen dumps seeded
multi-format corpora (native, Jaeger, Zipkin; ~50k traces each, `LONG_RUN=1`
for ~250k), then the local perf-sentinel binary runs `analyze`, `bench`,
`report` and `diff` on them.

This scenario is also the generator's acceptance test: the planted
`n_plus_one` count must reconcile with the detected `n_plus_one_sql`
findings (exact by construction for that pattern), and the three formats
must agree at equal seed.

## Run

```bash
make verify-limit-batch-volume
# deep corpus:
LONG_RUN=1 make verify-limit-batch-volume
```

Requires `cargo build --release` in the perf-sentinel checkout
(`PERF_SENTINEL_LOCAL_BIN` to override the binary path).

## Asserts

- `analyze` exits 0 in under 120 s per shard, per format.
- Detected `n_plus_one_sql` within ±20% of planted, formats within ±10%
  of each other.
- `bench` peak RSS under 2 GiB.
- `report` HTML under 6 MiB with the findings table present.
- `diff` exits 0 or 1 with parseable JSON.
- An input past `max_payload_size` is rejected loudly, naming the limit.
