# `chart-prometheusrule-pdb` scenario

Locks the **0.8.13 Phase A** chart additions (tracked at chart `0.2.63`): the opt-in
`PrometheusRule` and `PodDisruptionBudget` templates. Both default to disabled.

The lab does **not** vendor the chart. The daemon ships via
`manifests/perf-sentinel-daemon.yaml`. This scenario renders the upstream chart
(`charts/perf-sentinel/` in the perf-sentinel product repo) and validates:

1. render `flags-on` (`prometheusRule.enabled`, `prometheusRule.energyScrapers`,
   `podDisruptionBudget.enabled`) → `kubeconform -strict -ignore-missing-schemas`,
   0 invalid (mirrors the product CI `flags-on` leg).
2. `promtool check rules` on the PrometheusRule `spec.groups` (the product CI
   does **not** run promtool. We add it).
3. every alert expr references a real daemon metric (the 11 names: chart 0.2.63
   dropped the findings-store near-cap alert and its `…_stored_findings` /
   `…_max_retained_findings` metrics: `perf_sentinel_active_traces`,
   `…_otlp_rejected_total`, `…_analysis_shed_traces_total`,
   `…_analysis_queue_depth`/`_capacity`, `…_correlator_pairs_evicted_total`,
   `…_service_io_ops_overflow_total`, and the four
   `…_{scaphandre,kepler,redfish,cloud_energy}_last_scrape_age_seconds`).
4. PDB edge cases: `minAvailable=0` renders `minAvailable: 0` (NOT
   `maxUnavailable`). The default renders `maxUnavailable: 1`.
   `apiVersion policy/v1`.
5. if the cluster has the Prometheus-Operator CRD, `helm install` (no `--wait`,
   the chart appVersion image need not exist) → PrometheusRule + PDB admitted.
   Otherwise SKIP.

## Run

```
make verify-chart-prometheusrule-pdb
# chart path override:
PERF_SENTINEL_CHART=/path/to/charts/perf-sentinel make verify-chart-prometheusrule-pdb
```

Needs `helm` + `python3`. Uses `kubeconform` and `promtool` when present (else
the matching sub-test is SKIPped). The default chart path is
`${PERF_SENTINEL_REPO_PATH:-~/RustroverProjects/perf-sentinel}/charts/perf-sentinel`.
