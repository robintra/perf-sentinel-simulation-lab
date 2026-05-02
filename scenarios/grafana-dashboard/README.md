# Grafana dashboard validation

Validate the upstream `examples/grafana-dashboard.json` end-to-end on
the lab cluster, audit metric coverage against what the daemon exposes,
ship an extended overlay covering every metric upstream does not use,
load 5 PrometheusRules, deploy `postgres-exporter` and unlock the
`perf-sentinel report --pg-stat-prometheus <url>` path.

This scenario absorbs the S2-quater Postgres deep dive : the per-op
coefficient scoring (SELECT 0.5x, INSERT/UPDATE 1.5x, DELETE 1.2x) is
already covered by 3 unit tests upstream
(`crates/sentinel-core/src/score/mod.rs:2053-2188`), so only the
postgres-exporter deployment and the Prometheus path of `--pg-stat`
land here.

## Run

```bash
make verify-grafana-dashboard
# skip the 3 min daemon-down trigger test:
SKIP_TRIGGER_TEST=1 make verify-grafana-dashboard
# skip the 5 min validate-findings traffic step:
SKIP_TRAFFIC=1 make verify-grafana-dashboard
```

Report lands at `/tmp/scenario-grafana-dashboard-report.md`.

## What it validates

1. The 8 upstream panels render against live Prometheus (every `expr`
   returns at least one time series after `make validate-findings`).
2. The 6 perf_sentinel_* metrics referenced by upstream are all exposed
   by daemon 0.5.16 (zero broken references).
3. The 6 metrics exposed but not covered by upstream are surfaced as
   extension targets and consumed by the lab's extended overlay.
4. The extended overlay (9 panels) imports cleanly and the Grafana
   sidecar picks it up.
5. The 5 PrometheusRules load via the kube-prometheus-stack operator.
6. `PerfSentinelDaemonDown` fires when the daemon scales to 0
   (end-to-end alert path), the other 4 rules are validated as
   "loaded and parses" only.
7. postgres-exporter Deployment ready, Service exposed on :9187,
   ServiceMonitor scraped by Prometheus, `pg_stat_statements_seconds_total`
   queryable.

## Coverage audit

Daemon 0.5.16 exposes 12 perf_sentinel_* metrics
(`crates/sentinel-core/src/report/metrics.rs`). Upstream uses 6, the
lab's extended overlay uses the other 6 plus 2 standard
(`up`, `process_start_time_seconds`) and 2 postgres-exporter metrics.

| Metric | Used by upstream | Used by extended | Notes |
| --- | --- | --- | --- |
| `perf_sentinel_findings_total` | yes | no | 3 panels in upstream |
| `perf_sentinel_io_waste_ratio` | yes | no | gauge panel |
| `perf_sentinel_active_traces` | yes | no | stat panel |
| `perf_sentinel_events_processed_total` | yes | no | timeseries |
| `perf_sentinel_service_io_ops_total` | yes | no | per-service rate |
| `perf_sentinel_slow_duration_seconds` | yes | no | histogram, p95 |
| `perf_sentinel_traces_analyzed_total` | no | yes | trace cadence stat |
| `perf_sentinel_total_io_ops` | no | yes | cumulative gauge |
| `perf_sentinel_avoidable_io_ops` | no | yes | GreenOps trend |
| `perf_sentinel_scaphandre_last_scrape_age_seconds` | no | yes | energy ingestion freshness |
| `perf_sentinel_cloud_energy_last_scrape_age_seconds` | no | yes | energy ingestion freshness |
| `perf_sentinel_export_report_requests_total` | no | yes | self-monitoring |

## Upstream backlog (referenced in the original brief, not exposed by 0.5.16)

| Metric | Why it would matter |
| --- | --- |
| `perf_sentinel_co2_grams_total` | GreenOps Phase 9 carbon trend |
| `perf_sentinel_co2_per_request` | GreenOps per-request attribution |
| `perf_sentinel_regional_carbon_intensity` | regional context |
| `perf_sentinel_correlations_total` | cross-trace correlator volume |
| `perf_sentinel_pool_saturation_*` | per-pattern visibility |
| `perf_sentinel_chatty_service_*` | per-pattern visibility |

These are tracked in the lab memory's perf-sentinel followup as item 6
(OPEN, Phase 9 backlog).

## Alert rules

| Alert | Severity | Trigger | Validation |
| --- | --- | --- | --- |
| PerfSentinelDaemonDown | critical | `up{job="perf-sentinel-daemon"} == 0` for 2m | end-to-end (scale to 0, expect firing) |
| PerfSentinelHighIOWasteRatio | warning | `perf_sentinel_io_waste_ratio > 0.30` for 10m | rule loaded |
| PerfSentinelCriticalFindingsSurge | critical | `increase(...{severity="critical"}[1h]) > 5` for 5m | rule loaded |
| PerfSentinelActiveTracesNearCapacity | warning | `perf_sentinel_active_traces > 8000` for 5m | rule loaded |
| PerfSentinelEventProcessingStalled | warning | `rate(events_processed_total[5m]) == 0` for 5m | rule loaded |

Thresholds (0.30 waste, 5 critical/h, 8000 traces) are starting
points, tune in production. Routing to Slack/PagerDuty/email stays
user-config via Alertmanager `route` and `receivers`.

## postgres-exporter integration

Deployed in namespace `db` next to Postgres, exposes `:9187`, scraped
every 15s. Activates the panel `Top 10 slow queries (pg_stat)` in the
extended overlay (non-conditional after this scenario lands) and the
Path 2 of `scenarios/pg-stat/verify.sh` :

```bash
docker run --rm \
  --network host \
  -v /tmp/pg-stat:/output \
  ghcr.io/robintra/perf-sentinel:0.5.16 \
  report \
    --input /input/traces.json \
    --pg-stat-prometheus "http://localhost:9090" \
    --output /output/dashboard-prometheus.html
```

NetworkPolicies updated in `manifests/network-policies.yaml` (rules
4.J and 4.J.bis appended). DNS egress and Prometheus-scrape ingress
were already covered by the lab's namespace-wide policies, so only
postgres-exporter -> postgres egress and postgres <- postgres-exporter
ingress are new.

## Limitations

- Lab dashboard at `manifests/grafana-dashboards/perf-sentinel-overview.json`
  is a custom French-labeled artifact, not a copy of upstream. Both
  dashboards coexist in Grafana via distinct uids
  (`perf-sentinel-overview` and `perf-sentinel-overview-upstream`,
  the latter renamed at apply time by `verify.sh`).
- The 4 alert rules other than `PerfSentinelDaemonDown` are validated
  as "rule parses and loads" only. End-to-end firing requires crafted
  load (waste ratio > 0.30, 5+ critical findings/h, 8000+ active
  traces) or stopping the OTLP pipeline. README documents this.
- postgres-exporter reuses the `lab` user. In production, prefer a
  dedicated read-only role.
- This scenario is local-only, like the other 8. The
  `validate-on-release.yml` workflow covers minimal sanity targets,
  not the scenario suite (cluster footprint exceeds GHA capacity).

## Files

| File | Purpose |
| --- | --- |
| `verify.sh` | Orchestration, idempotent re-runs, ~5-8 min wall clock |
| `dashboard-upstream.json` | Verbatim copy of upstream `examples/grafana-dashboard.json`, applied with mutated uid+title |
| `dashboard-extended.json` | 9 lab panels covering exposed-but-unused daemon metrics + postgres-exporter |
| `postgres-exporter.yaml` | Secret + Deployment + Service + ServiceMonitor in namespace `db` |
| `alertrules.yaml` | PrometheusRule with 5 alerts in namespace `observability` |
