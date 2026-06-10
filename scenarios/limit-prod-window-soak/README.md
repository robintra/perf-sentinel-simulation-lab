# limit-prod-window-soak

The production window config (`trace_ttl_ms = 30000`,
`max_active_traces = 10000`) under sustained mixed load: 60 tps for 10
minutes (`LONG_RUN=1`: 120 tps for 30 minutes).

## Run

```bash
make verify-limit-prod-window-soak
```

## Asserts

- `active_traces` plateaus near tps x 30 s (±50%) and stays far from the
  10000 cap: TTL eviction works at the production window.
- RSS drift between the warm window and the tail stays under 10%
  (long-running-drift analysis).
- Zero shed and zero channel_full at this rate, zero restarts.
- 90 s after the load stops, the window drains below 100 traces.
