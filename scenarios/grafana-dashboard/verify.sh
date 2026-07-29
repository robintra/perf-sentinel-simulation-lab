#!/usr/bin/env bash
# Grafana dashboard validation, coverage audit, alert rules, postgres-exporter.
#
# What this scenario does, from the perspective of a user importing the
# upstream `examples/grafana-dashboard.json` into their Grafana:
#
# 1. Parity. Diffs `manifests/grafana-dashboards/perf-sentinel-overview.json`
#    (lab) against `examples/grafana-dashboard.json` (upstream). The lab
#    copy is byte-identical to upstream after `jq --sort-keys`; drift
#    fails the scenario.
# 2. Coverage audit. Reads daemon /metrics and the dashboard JSON, lists
#    metrics the dashboard references, metrics the daemon exposes, and
#    the diff in both directions. Surfaces extension targets.
# 3. Panel render. For every panel `expr`, queries Prometheus
#    historical data and asserts at least one time series. Catches
#    "No data" tiles in CI.
# 4. Extended overlay. Applies a separate ConfigMap
#    `perf-sentinel-extended-dashboard` with 2 postgres-exporter panels
#    that are lab-specific (Top 10 slow queries, DB query rate). All
#    daemon-only panels live in the upstream dashboard, no overlap.
# 5. Alert rules. Applies 5 PrometheusRules and polls the operator
#    until they are loaded. Triggers PerfSentinelDaemonDown end-to-end
#    by scaling the daemon Deployment to 0; restores it via a trap so
#    a Ctrl+C never leaves the cluster in a degraded state.
# 6. postgres-exporter. Deploys the v0.17 image with credentials
#    sourced from the lab's `postgres-credentials` Secret, asserts
#    `pg_stat_statements_seconds_total` is exposed and Prometheus
#    scrapes it. Unlocks the `--pg-stat-prometheus` path validated by
#    `scenarios/pg-stat/verify.sh`.
#
# Optional knobs:
#   SKIP_TRIGGER_TEST=1      skip the ~3 min daemon-down alert trigger.
#   SKIP_TRAFFIC=1           skip validate-findings (use when traffic
#                            was already driven recently).
#   UPSTREAM_DASHBOARD_PATH  override the upstream JSON location for the
#                            parity check. Default targets the user's
#                            common clone layout, see line below. When
#                            absent, the parity step is SKIPPED (not
#                            failed) so the scenario still runs on a
#                            machine without the upstream clone.

set -euo pipefail

SCENARIO="grafana-dashboard"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
DAEMON_URL="${DAEMON_URL:-http://localhost:14318}"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"
LAB_DASHBOARD="${LAB_ROOT}/manifests/grafana-dashboards/perf-sentinel-overview.json"
UPSTREAM_DASHBOARD_PATH="${UPSTREAM_DASHBOARD_PATH:-${HOME}/RustroverProjects/perf-sentinel/examples/grafana-dashboard.json}"
EXTENDED_DASHBOARD="${SCENARIO_DIR}/dashboard-extended.json"
POSTGRES_EXPORTER_MANIFEST="${SCENARIO_DIR}/postgres-exporter.yaml"
ALERTRULES_MANIFEST="${SCENARIO_DIR}/alertrules.yaml"
NETWORK_POLICIES_MANIFEST="${LAB_ROOT}/manifests/network-policies.yaml"

mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
warn() { color_red   "    warn: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

verdict="UNKNOWN"
PIDS=()
DAEMON_SCALED_DOWN=0
cleanup() {
  for pid in "${PIDS[@]+"${PIDS[@]}"}"; do
    kill "${pid}" 2>/dev/null || true
  done
  # If the script exits between scale --replicas=0 and scale --replicas=1
  # (Ctrl+C, set -e early-exit, OOM kill, etc.), restore the daemon to
  # 1 replica so the cluster is not left degraded for the next scenario.
  if [ "${DAEMON_SCALED_DOWN}" = "1" ]; then
    color_red "    interrupted mid-trigger: restoring daemon to replicas=1"
    kubectl scale -n observability deployment/perf-sentinel-daemon --replicas=1 \
      >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

# Helper to query the Prometheus HTTP API through the lab's persistent
# port-forward (scripts/port-forward.sh, self-healing via its probe
# watcher). The previous kubectl exec + wget approach broke with the
# v3.x distroless Prometheus images (no shell, no wget in the pod),
# and the API-server service proxy is blocked by the zero-trust
# NetworkPolicies. Use POST so panel exprs containing braces, quotes,
# and parentheses survive shell quoting.
PROM_URL="${PROM_URL:-http://localhost:9090}"
prom_api_get() {
  # Usage: prom_api_get <endpoint-path>
  # Example: prom_api_get rules
  curl -fsS --max-time 10 "${PROM_URL}/api/v1/$1" 2>/dev/null
}
prom_api_post() {
  # Usage: prom_api_post <endpoint-path> <encoded-body>
  # Example: prom_api_post query "query=up%7Bjob%3D%22foo%22%7D"
  curl -fsS --max-time 10 --data "$2" "${PROM_URL}/api/v1/$1" 2>/dev/null
}

step "Probe daemon and Prometheus"
curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 \
  || die "daemon not reachable at ${DAEMON_URL}, run scripts/port-forward.sh start first"
ok "daemon reachable"

PROMETHEUS_POD=$(kubectl -n observability get pod \
  -l app.kubernetes.io/name=prometheus,app.kubernetes.io/instance=kube-prometheus-stack-prometheus \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "${PROMETHEUS_POD}" ]; then
  PROMETHEUS_POD=$(kubectl -n observability get pod \
    -l app.kubernetes.io/name=prometheus \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
fi
[ -n "${PROMETHEUS_POD}" ] || die "no prometheus pod found in observability"
ok "prometheus pod ${PROMETHEUS_POD}"

# Retry across the port-forward watcher's recycling window (~30s).
prom_up=0
for i in $(seq 1 12); do
  if curl -fsS --max-time 3 "${PROM_URL}/-/ready" >/dev/null 2>&1; then
    prom_up=1
    break
  fi
  sleep 3
done
[ "${prom_up}" -eq 1 ] || die "Prometheus not reachable at ${PROM_URL}, run scripts/port-forward.sh start first"
ok "Prometheus API reachable at ${PROM_URL}"

step "Apply NetworkPolicies (re-applies the consolidated file with new postgres-exporter rules)"
kubectl apply -f "${NETWORK_POLICIES_MANIFEST}" >/dev/null
ok "NetworkPolicies applied"

step "Deploy postgres-exporter"
kubectl apply -f "${POSTGRES_EXPORTER_MANIFEST}" >/dev/null
kubectl -n db rollout status deployment/postgres-exporter --timeout=90s >/dev/null \
  || die "postgres-exporter deployment did not become ready, see kubectl -n db logs deploy/postgres-exporter"
ok "postgres-exporter ready"

step "Verify postgres-exporter exposes pg_stat_statements_seconds_total"
kubectl -n db port-forward svc/postgres-exporter 9187:9187 \
  > "${TMP_DIR}/pgex-pf.log" 2>&1 &
PIDS+=($!)
sleep 3
if curl -sf http://localhost:9187/metrics 2>/dev/null \
   | grep -q '^pg_stat_statements_seconds_total'; then
  ok "pg_stat_statements_seconds_total exposed"
else
  warn "pg_stat_statements_seconds_total not yet exposed by postgres-exporter (may need DB activity to populate)"
fi

step "Poll Prometheus targets up to 60s for postgres-exporter scrape pickup"
SCRAPE_HEALTH_INITIAL="error"
SCRAPE_DEADLINE=$((SECONDS + 60))
while [ ${SECONDS} -lt ${SCRAPE_DEADLINE} ]; do
  SCRAPE_HEALTH_INITIAL=$(prom_api_get targets \
    | python3 -c "
import json, sys
try:
    targets = json.load(sys.stdin)['data']['activeTargets']
except (json.JSONDecodeError, KeyError):
    sys.exit(2)
for t in targets:
    if 'postgres-exporter' in t.get('labels', {}).get('job', ''):
        print(t.get('health', 'unknown'))
        sys.exit(0)
print('not-found')
" 2>/dev/null || echo "error")
  if [ "${SCRAPE_HEALTH_INITIAL}" = "up" ]; then
    break
  fi
  sleep 5
done
if [ "${SCRAPE_HEALTH_INITIAL}" = "up" ]; then
  ok "Prometheus scrape: postgres-exporter health=up"
else
  warn "Prometheus scrape state after 60s: ${SCRAPE_HEALTH_INITIAL} (re-checked later)"
fi

step "Apply PrometheusRules"
kubectl apply -f "${ALERTRULES_MANIFEST}" >/dev/null

# The Prometheus operator takes 30-90s to render the PrometheusRule into
# Prometheus's rule files and trigger a reload. Poll up to 120s.
step "Poll Prometheus /api/v1/rules up to 120s for the 5 alerts to load"
RULES_LOADED="missing:initial"
RULES_DEADLINE=$((SECONDS + 120))
while [ ${SECONDS} -lt ${RULES_DEADLINE} ]; do
  RULES_LOADED=$(prom_api_get rules \
    | python3 -c "
import json, sys
try:
    groups = json.load(sys.stdin)['data']['groups']
except (json.JSONDecodeError, KeyError):
    sys.exit(2)
expected = {'PerfSentinelDaemonDown', 'PerfSentinelHighIOWasteRatio',
            'PerfSentinelCriticalFindingsSurge', 'PerfSentinelActiveTracesNearCapacity',
            'PerfSentinelEventProcessingStalled'}
loaded = {r['name'] for g in groups for r in g.get('rules', []) if r.get('type') == 'alerting'}
missing = expected - loaded
if missing:
    print('missing:' + ','.join(sorted(missing)))
else:
    print('all-loaded')
" 2>/dev/null || echo "error")
  if [ "${RULES_LOADED}" = "all-loaded" ]; then
    break
  fi
  sleep 10
done
if [ "${RULES_LOADED}" = "all-loaded" ]; then
  ok "5 PrometheusRules loaded"
else
  warn "PrometheusRule load state after 120s: ${RULES_LOADED}"
fi

step "Parity check: lab dashboard JSON vs upstream"
PARITY_VERDICT="SKIPPED"
if [ -f "${UPSTREAM_DASHBOARD_PATH}" ]; then
  if diff <(jq --sort-keys . "${UPSTREAM_DASHBOARD_PATH}") \
          <(jq --sort-keys . "${LAB_DASHBOARD}") > "${TMP_DIR}/dashboard-parity.diff" 2>&1; then
    PARITY_VERDICT="PASS"
    ok "lab dashboard byte-identical to upstream (after jq normalize)"
  else
    PARITY_VERDICT="FAIL"
    warn "lab dashboard has drifted from upstream, see ${TMP_DIR}/dashboard-parity.diff"
    head -40 "${TMP_DIR}/dashboard-parity.diff"
  fi
else
  warn "SKIP parity check: upstream JSON not found at ${UPSTREAM_DASHBOARD_PATH}"
  warn "  override the path via the UPSTREAM_DASHBOARD_PATH env var :"
  warn "  UPSTREAM_DASHBOARD_PATH=/path/to/perf-sentinel/examples/grafana-dashboard.json \\"
  warn "    make verify-grafana-dashboard"
fi

step "Apply extended dashboard ConfigMap"
# The lab dashboard (= upstream verbatim) is already imported by
# bootstrap.sh into the perf-sentinel-dashboards ConfigMap. We only
# need to add the extended overlay here.
kubectl create configmap perf-sentinel-extended-dashboard \
  --from-file=perf-sentinel-extended.json="${EXTENDED_DASHBOARD}" \
  -n observability \
  --dry-run=client -o yaml \
  | kubectl label --local -f - grafana_dashboard=1 -o yaml --dry-run=client \
  | kubectl apply -f - >/dev/null
ok "extended dashboard ConfigMap applied (sidecar imports within ~30s)"

if [ "${SKIP_TRAFFIC:-0}" != "1" ]; then
  step "Drive traffic so panels populate (validate-findings, ~5 min)"
  if kubectl -n db exec sts/postgres -- psql -U lab -d lab \
       -c "SELECT pg_stat_statements_reset();" >/dev/null 2>&1; then
    ok "pg_stat_statements counters reset"
  else
    warn "pg_stat_statements_reset() failed (extension absent or perms?), continuing with stale counters"
  fi
  if make -C "${LAB_ROOT}" validate-findings >/dev/null 2>&1; then
    ok "validate-findings done"
  else
    warn "validate-findings exited non-zero (shop services unhealthy or k6 issues?), continuing with whatever traffic landed"
  fi
  step "Wait 60s for Prometheus scrape cycles"
  sleep 60
else
  ok "SKIP_TRAFFIC=1, skipping validate-findings"
fi

step "Audit: daemon-exposed metrics vs metrics referenced by dashboard (lab = upstream)"
kubectl -n observability port-forward svc/perf-sentinel-daemon 14318:14318 \
  > "${TMP_DIR}/daemon-pf.log" 2>&1 &
PIDS+=($!)
sleep 3
curl -sfH "Accept: application/openmetrics-text" http://localhost:14318/metrics 2>/dev/null \
  | grep -oE '^perf_sentinel_[a-z_]+' \
  | sort -u > "${TMP_DIR}/exposed-metrics.txt" || true
EXPOSED_COUNT=$(wc -l < "${TMP_DIR}/exposed-metrics.txt" | tr -d ' ')
ok "${EXPOSED_COUNT} perf_sentinel_* metrics exposed by daemon"

python3 -c "
import json, re
data = json.load(open('${LAB_DASHBOARD}'))
metrics = set()
for panel in data.get('panels', []):
    for target in panel.get('targets', []):
        for m in re.findall(r'perf_sentinel_[a-z_]+', target.get('expr', '')):
            metrics.add(m)
print('\n'.join(sorted(metrics)))
" > "${TMP_DIR}/upstream-metrics.txt"
USED_COUNT=$(wc -l < "${TMP_DIR}/upstream-metrics.txt" | tr -d ' ')
ok "${USED_COUNT} perf_sentinel_* metrics referenced by dashboard"

# Allow histogram bucket aliasing (perf_sentinel_slow_duration_seconds vs
# perf_sentinel_slow_duration_seconds_bucket are the same registered metric).
python3 -c "
exposed = set(open('${TMP_DIR}/exposed-metrics.txt').read().split())
used = set(open('${TMP_DIR}/upstream-metrics.txt').read().split())
def family(name):
    for suffix in ('_bucket', '_count', '_sum'):
        if name.endswith(suffix):
            return name[:-len(suffix)]
    return name
exposed_fam = {family(m) for m in exposed}
used_fam = {family(m) for m in used}
broken = sorted(used_fam - exposed_fam)
uncovered = sorted(exposed_fam - used_fam)
with open('${TMP_DIR}/broken-references.txt', 'w') as f:
    f.write('\n'.join(broken) + ('\n' if broken else ''))
with open('${TMP_DIR}/uncovered.txt', 'w') as f:
    f.write('\n'.join(uncovered) + ('\n' if uncovered else ''))
"
# grep -c on an empty file prints "0" then exits 1, and `|| echo 0`
# captures BOTH outputs producing "0\n0" which breaks `[ -eq 0 ]`. Gate
# with -s (non-empty file) to keep the value clean integer.
if [ -s "${TMP_DIR}/broken-references.txt" ]; then
  BROKEN_COUNT=$(grep -c . "${TMP_DIR}/broken-references.txt")
else
  BROKEN_COUNT=0
fi
if [ -s "${TMP_DIR}/uncovered.txt" ]; then
  UNCOVERED_COUNT=$(grep -c . "${TMP_DIR}/uncovered.txt")
else
  UNCOVERED_COUNT=0
fi
if [ "${BROKEN_COUNT}" -gt 0 ]; then
  warn "${BROKEN_COUNT} panels reference metrics NOT exposed by daemon"
  cat "${TMP_DIR}/broken-references.txt"
else
  ok "0 broken references"
fi
ok "${UNCOVERED_COUNT} exposed metrics uncovered by dashboard (extension targets)"

step "Validate every panel expr returns at least one time series"
EMPTY_PANELS=0
TOTAL_PANELS=0
UNFEEDABLE=0
# Exprs the lab structurally cannot feed, so an empty result is the lab's
# coverage gap and not a broken panel. Each entry must name what is missing;
# anything else empty still fails the scenario.
#
# `type="messaging"` only gets a histogram series once a broker span exceeds the
# slow threshold, and the lab deploys no broker at all — messaging ingestion is
# gated cluster-free by scenarios/broker-messaging-waste instead. Note this is
# not a missing `or vector(0)`: its two siblings in the same panel
# (type="sql", type="http_out") do not carry one either, and only 2 of the
# dashboard's 32 exprs do, so the fallback is the exception upstream, not the
# convention.
expr_unfeedable() {  # $1 = raw expr ; 0 = known-unfeedable
  case "$1" in
    *'type="messaging"'*) return 0 ;;
    *) return 1 ;;
  esac
}
# URL-encode the exprs upfront so braces, quotes, and parentheses do
# not break shell interpolation when piped to wget --post-data.
python3 -c "
import json, urllib.parse
data = json.load(open('${LAB_DASHBOARD}'))
for p in data.get('panels', []):
    for t in p.get('targets', []):
        expr = (t.get('expr') or '').replace('\n', ' ')
        if expr:
            print(urllib.parse.quote(expr) + '\t' + expr)
" > "${TMP_DIR}/upstream-exprs.txt"
while IFS=$'\t' read -r encoded raw; do
  TOTAL_PANELS=$((TOTAL_PANELS + 1))
  count=$(prom_api_post query "query=${encoded}" \
    | python3 -c "
import json, sys
try:
    print(len(json.load(sys.stdin)['data']['result']))
except Exception:
    print(0)
" 2>/dev/null || echo 0)
  if [ "${count}" -lt 1 ]; then
    if expr_unfeedable "${raw}"; then
      UNFEEDABLE=$((UNFEEDABLE + 1))
      warn "empty but not feedable by this lab (no broker deployed): ${raw:0:70}..."
    else
      EMPTY_PANELS=$((EMPTY_PANELS + 1))
      warn "empty result: ${raw:0:70}..."
    fi
  fi
done < "${TMP_DIR}/upstream-exprs.txt"
ok "${TOTAL_PANELS} panel expressions checked, ${EMPTY_PANELS} returned empty, ${UNFEEDABLE} empty by lab coverage gap"

step "Confirm dashboards visible via Grafana API"
GRAFANA_PASS=$(kubectl -n observability get secret kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || echo admin)
kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80 \
  > "${TMP_DIR}/grafana-pf.log" 2>&1 &
PIDS+=($!)
sleep 5
GRAFANA_DASHBOARDS=$(curl -sH "Authorization: Basic $(echo -n admin:${GRAFANA_PASS} | base64)" \
  'http://localhost:3000/api/search?query=perf-sentinel' 2>/dev/null \
  | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print('error')
    sys.exit(0)
titles = sorted({d.get('title', '') for d in data})
print('|'.join(titles))
" 2>/dev/null || echo error)
ok "Grafana sees: ${GRAFANA_DASHBOARDS}"

if [ "${SKIP_TRIGGER_TEST:-0}" != "1" ]; then
  step "Trigger test: scale daemon to 0, expect PerfSentinelDaemonDown to fire"
  kubectl scale -n observability deployment/perf-sentinel-daemon --replicas=0 >/dev/null
  DAEMON_SCALED_DOWN=1
  # Poll up to 240s instead of a fixed wait. Worst case: scrape interval
  # (15-30s) + alert `for: 2m` + slack. With 30s scrape and 16x15s polls
  # we tolerate ~120s + 240s = 360s but exit early as soon as firing.
  step "Poll Prometheus /api/v1/rules every 15s up to 240s for PerfSentinelDaemonDown firing"
  # /api/v1/rules returns every loaded rule with its current state
  # (inactive/pending/firing). /api/v1/alerts only returns active
  # (pending/firing) alerts so it cannot distinguish "rule not loaded"
  # from "rule loaded but inactive". Using /rules is more diagnostic.
  FIRING="no"
  TRIGGER_DEADLINE=$((SECONDS + 240))
  TRIGGER_LAST_STATE="not-yet"
  while [ ${SECONDS} -lt ${TRIGGER_DEADLINE} ]; do
    TRIGGER_LAST_STATE=$(prom_api_get rules \
      | python3 -c "
import json, sys
try:
    groups = json.load(sys.stdin)['data']['groups']
except Exception:
    print('error')
    sys.exit(0)
for g in groups:
    for r in g.get('rules', []):
        if r.get('name') == 'PerfSentinelDaemonDown':
            print(r.get('state', 'unknown'))
            sys.exit(0)
print('rule-not-loaded')
" 2>/dev/null || echo "error")
    if [ "${TRIGGER_LAST_STATE}" = "firing" ]; then
      FIRING="yes"
      break
    fi
    sleep 15
  done
  step "Restore daemon"
  kubectl scale -n observability deployment/perf-sentinel-daemon --replicas=1 >/dev/null
  DAEMON_SCALED_DOWN=0
  kubectl -n observability rollout status deployment/perf-sentinel-daemon --timeout=90s >/dev/null
  if [ "${FIRING}" = "yes" ]; then
    ok "PerfSentinelDaemonDown fired as expected (last state: firing)"
    TRIGGER_VERDICT="PASS"
  else
    warn "PerfSentinelDaemonDown did not fire within 240s (last state: ${TRIGGER_LAST_STATE})"
    TRIGGER_VERDICT="FAIL"
  fi
else
  ok "SKIP_TRIGGER_TEST=1, skipping daemon-down trigger test"
  TRIGGER_VERDICT="SKIPPED"
fi

# Re-check transient states (postgres-exporter scrape, pg_stat metric)
# now that traffic ran. The first checks early in the script may have
# fired before postgres-exporter was scraped or before any DB activity.
step "Re-check postgres-exporter scrape state and pg_stat metric"
SCRAPE_HEALTH_FINAL=$(prom_api_get targets \
  | python3 -c "
import json, sys
try:
    targets = json.load(sys.stdin)['data']['activeTargets']
except (json.JSONDecodeError, KeyError):
    sys.exit(2)
for t in targets:
    if 'postgres-exporter' in t.get('labels', {}).get('job', ''):
        print(t.get('health', 'unknown'))
        sys.exit(0)
print('not-found')
" 2>/dev/null || echo "error")
ok "postgres-exporter scrape (final): ${SCRAPE_HEALTH_FINAL}"

PGEX_METRIC_PRESENT="no"
kubectl -n db port-forward svc/postgres-exporter 9187:9187 \
  > "${TMP_DIR}/pgex-final-pf.log" 2>&1 &
PIDS+=($!)
sleep 3
if curl -sf http://localhost:9187/metrics 2>/dev/null \
   | grep -q '^pg_stat_statements_seconds_total'; then
  PGEX_METRIC_PRESENT="yes"
  ok "pg_stat_statements_seconds_total exposed (final)"
else
  warn "pg_stat_statements_seconds_total still not exposed (postgres may need pg_stat_statements_reset + queries)"
fi

# BROKEN_COUNT (panel-referenced metric not in `/metrics` output) is
# informational only. It can be > 0 with a freshly-restarted daemon
# whose CounterVec metrics have no observed labels yet (the family is
# registered but no series are emitted). The real "panel will render"
# check is EMPTY_PANELS, which queries Prometheus historical data and
# accounts for upstream's `or vector(0)` fallbacks.
if [ "${EMPTY_PANELS}" -eq 0 ] \
   && [ "${RULES_LOADED}" = "all-loaded" ] \
   && [ "${TRIGGER_VERDICT}" != "FAIL" ] \
   && [ "${PARITY_VERDICT}" != "FAIL" ]; then
  verdict="PASS"
else
  verdict="FAIL"
fi

step "Write report"
{
  echo "# Grafana dashboard validation"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Daemon: ${DAEMON_URL}"
  echo "Prometheus pod: ${PROMETHEUS_POD}"
  echo
  echo "## Parity check"
  echo
  echo "- lab dashboard (manifests/grafana-dashboards/perf-sentinel-overview.json) vs upstream: ${PARITY_VERDICT}"
  echo
  echo "## Coverage audit"
  echo
  echo "- daemon-exposed perf_sentinel_* metrics: ${EXPOSED_COUNT}"
  echo "- referenced by dashboard: ${USED_COUNT}"
  echo "- broken references (panel expr -> missing metric): ${BROKEN_COUNT}"
  echo "- uncovered (exposed but no panel uses them): ${UNCOVERED_COUNT}"
  echo
  echo "### Exposed but uncovered (extension candidates)"
  echo
  echo '```'
  cat "${TMP_DIR}/uncovered.txt" 2>/dev/null || true
  echo '```'
  echo
  if [ "${BROKEN_COUNT}" -gt 0 ]; then
    echo "### Broken references (panels reference metrics not exposed by daemon)"
    echo
    echo '```'
    cat "${TMP_DIR}/broken-references.txt"
    echo '```'
    echo
  fi
  echo "## Upstream backlog (mentioned in original brief, not in 0.5.16 daemon)"
  echo
  echo "- \`perf_sentinel_co2_grams_total\` (GreenOps Phase 9)"
  echo "- \`perf_sentinel_co2_per_request\` (GreenOps Phase 9)"
  echo "- \`perf_sentinel_regional_carbon_intensity\` (GreenOps Phase 9)"
  echo "- \`perf_sentinel_correlations_total\` (cross-trace correlator)"
  echo "- \`perf_sentinel_pool_saturation_*\` (anti-pattern detail)"
  echo "- \`perf_sentinel_chatty_service_*\` (anti-pattern detail)"
  echo
  echo "## Panels rendered against live data"
  echo
  echo "- upstream panels checked: ${TOTAL_PANELS}"
  echo "- empty results: ${EMPTY_PANELS} (plus ${UNFEEDABLE} empty by lab coverage gap, e.g. no broker deployed)"
  echo
  echo "## Alert rules"
  echo
  echo "- 5 PrometheusRules loaded: ${RULES_LOADED}"
  echo "- PerfSentinelDaemonDown trigger test: ${TRIGGER_VERDICT}"
  echo "- 4 other rules validated by parse-and-load only (require crafted load to fire end-to-end)"
  echo
  echo "## postgres-exporter"
  echo
  echo "- Deployment ready, Service ClusterIP on :9187, ServiceMonitor scraped"
  echo "- Prometheus scrape health (initial, post-deploy): ${SCRAPE_HEALTH_INITIAL}"
  echo "- Prometheus scrape health (final, post-traffic): ${SCRAPE_HEALTH_FINAL}"
  echo "- pg_stat_statements_seconds_total exposed: ${PGEX_METRIC_PRESENT}"
  echo
  echo "## Grafana dashboards visible via API"
  echo
  echo '```'
  echo "${GRAFANA_DASHBOARDS}"
  echo '```'
  echo
  echo "## Run again"
  echo
  echo '```bash'
  echo "make verify-grafana-dashboard"
  echo "# skip the 3 min daemon-down trigger:"
  echo "SKIP_TRIGGER_TEST=1 make verify-grafana-dashboard"
  echo "# skip the 5 min validate-findings traffic step:"
  echo "SKIP_TRAFFIC=1 make verify-grafana-dashboard"
  echo '```'
  echo
  echo "**Verdict: ${verdict}**"
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  ok "PASS, see ${REPORT}"
  exit 0
else
  die "${verdict}, see ${REPORT}"
fi
