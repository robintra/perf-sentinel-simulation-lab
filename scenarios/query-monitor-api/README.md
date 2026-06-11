# query-monitor-api

Validates the read-only daemon data plane that backs the
`perf-sentinel query monitor` operator TUI introduced in 0.8.8. The TUI
is a client-side terminal app (Advisor / Energy / Trends / Scrapers /
Config tabs); it is not driven headless here. This scenario asserts the
daemon endpoints it polls, all read-only and loopback-facing.

## What it covers

Five checks against the lab daemon (port-forwarded on `:14318` by
`scripts/port-forward.sh`, or any daemon via `DAEMON_URL`):

1. **`/api/config` parameters present.** The Config tab reads this new
   endpoint to render every `[daemon]` parameter with its current
   value. Asserts the expected keys are present (ports, window sizing,
   queue capacities, correlation sub-config, the boolean security
   summaries).

2. **`/api/config` secret-leak gate.** The headline security check,
   mirroring the daemon-side unit test
   `config_exposes_daemon_params_without_secrets`. The response is an
   explicit allowlist: TLS paths and the ack API key are reduced to
   `tls_configured` / `ack_api_key_set` booleans, and the ack / archive
   storage paths are never echoed. Asserts no secret-bearing key
   (`api_key`, `cert_path`, `key_path`, `storage_path`, ...) and no
   secret-bearing value (`/var/lib/perf-sentinel`, `acks.jsonl`, PEM
   markers) appears in the response.

3. **`/api/status` capacity fields.** The Trends tab reads the caps and
   live depths from the extended status. Asserts the 0.8.8 fields are
   present: `max_active_traces`, `analysis_queue_depth`,
   `analysis_queue_capacity`, `stored_findings`, `max_retained_findings`.

4. **`/api/energy` backends shape.** The Scrapers tab reads per-backend
   health from it. Asserts a well-formed `backends` array with the known
   backend names and that no backend secret (Electricity Maps key, etc.)
   leaks.

5. **`/metrics` six gauges.** The scalar gauges the upstream Grafana
   dashboard's Energy / Carbon / Headroom panels query:
   `perf_sentinel_energy_kwh`, `perf_sentinel_carbon_gco2`,
   `perf_sentinel_max_active_traces`,
   `perf_sentinel_analysis_queue_capacity`,
   `perf_sentinel_max_retained_findings`,
   `perf_sentinel_stored_findings`. Asserts all six are registered and
   exposed. Presence, not magnitude: they register at startup and read 0
   without traffic, which proves the wiring. Live magnitude (panels
   rendering against historical data) is covered by `grafana-dashboard`.

No traffic and no green backend are required: a freshly-started daemon
satisfies every check.

## Run

```bash
make verify-query-monitor-api
# against an arbitrary daemon (e.g. a local pre-release build):
DAEMON_URL=http://localhost:24318 make verify-query-monitor-api
```

Report: `/tmp/scenario-query-monitor-api-report.md`.
