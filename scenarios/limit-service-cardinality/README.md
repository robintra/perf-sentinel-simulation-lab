# limit-service-cardinality

1500 distinct `service.name` values (5000 in `LONG_RUN=1`) against the
daemon's hardcoded 1024-service metering cap, from a tracegen Job in the
`limit-testing` namespace.

Tear the shop fleet down first for clean numbers
(`scripts/teardown-services.sh`), and run `scripts/seed-tracegen.sh` once
to import the generator image.

## Run

```bash
make verify-limit-service-cardinality
LONG_RUN=1 make verify-limit-service-cardinality   # 5000 services + pair-eviction assert
```

## Asserts

- `perf_sentinel_service_io_ops_overflow_total` climbs (0.8.7 counter).
- Exactly 1024 `service_io_ops_total` series on `/metrics`.
- `/metrics` stays scrapeable: body < 1.5 MiB, scrape < 2 s.
- RSS < 230 MiB, zero restarts, daemon answers >= 70% of polls.
- Deep mode: `perf_sentinel_correlator_pairs_evicted_total` climbs.
