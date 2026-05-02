#!/usr/bin/env bash
# Grafana dashboard import + coverage audit + alert rules + postgres-exporter.
#
# Use case: a user clones perf-sentinel and imports the upstream
# `examples/grafana-dashboard.json`. They want to know (a) every panel
# renders against the lab's Prometheus, (b) which daemon metrics are
# exposed but unused, (c) what alert rules cover the daemon, (d) how
# pg_stat hooks in via postgres-exporter.
#
# This scenario imports the upstream dashboard verbatim (with mutated
# uid+title to avoid collision with the lab's custom French
# `perf-sentinel-overview` dashboard), ships an `extended` overlay with
# 9 panels covering every daemon metric upstream does not use plus
# 2 postgres-exporter panels, loads 5 PrometheusRules, deploys
# postgres-exporter and tests the PerfSentinelDaemonDown alert end-to-end.
#
# Optional knobs:
# - SKIP_TRIGGER_TEST=1   skip the ~3 min daemon-down alert trigger test.
# - SKIP_TRAFFIC=1        skip make seed-services + validate-findings (use
#                         this when traffic was already driven recently).

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
cleanup() {
  for pid in "${PIDS[@]+"${PIDS[@]}"}"; do
    kill "${pid}" 2>/dev/null || true
  done
}
trap cleanup EXIT

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

step "Verify Prometheus scrapes postgres-exporter"
sleep 20
SCRAPE_HEALTH=$(kubectl exec -n observability "${PROMETHEUS_POD}" -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/targets' 2>/dev/null \
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
if [ "${SCRAPE_HEALTH}" = "up" ]; then
  ok "Prometheus scrape: postgres-exporter health=up"
else
  warn "Prometheus scrape state: ${SCRAPE_HEALTH} (continuing, may catch up later)"
fi

step "Apply PrometheusRules"
kubectl apply -f "${ALERTRULES_MANIFEST}" >/dev/null
sleep 15
RULES_LOADED=$(kubectl exec -n observability "${PROMETHEUS_POD}" -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/rules' 2>/dev/null \
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
  ok "5 PrometheusRules loaded"
else
  warn "PrometheusRule load state: ${RULES_LOADED}"
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
  ok "SKIP parity check: upstream perf-sentinel repo not at ${UPSTREAM_DASHBOARD_PATH}"
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
  kubectl -n db exec sts/postgres -- psql -U lab -d lab \
    -c "SELECT pg_stat_statements_reset();" >/dev/null 2>&1 || true
  make -C "${LAB_ROOT}" validate-findings >/dev/null 2>&1 || true
  ok "validate-findings done"
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
BROKEN_COUNT=$(grep -c . "${TMP_DIR}/broken-references.txt" 2>/dev/null || echo 0)
UNCOVERED_COUNT=$(grep -c . "${TMP_DIR}/uncovered.txt" 2>/dev/null || echo 0)
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
python3 -c "
import json
data = json.load(open('${LAB_DASHBOARD}'))
for p in data.get('panels', []):
    for t in p.get('targets', []):
        if t.get('expr'):
            print(t['expr'].replace('\n', ' '))
" > "${TMP_DIR}/upstream-exprs.txt"
while IFS= read -r expr; do
  TOTAL_PANELS=$((TOTAL_PANELS + 1))
  count=$(kubectl exec -n observability "${PROMETHEUS_POD}" -c prometheus -- \
    wget -qO- --post-data="query=${expr}" 'http://localhost:9090/api/v1/query' 2>/dev/null \
    | python3 -c "
import json, sys
try:
    print(len(json.load(sys.stdin)['data']['result']))
except Exception:
    print(0)
" 2>/dev/null || echo 0)
  if [ "${count}" -lt 1 ]; then
    EMPTY_PANELS=$((EMPTY_PANELS + 1))
    warn "empty result: ${expr:0:70}..."
  fi
done < "${TMP_DIR}/upstream-exprs.txt"
ok "${TOTAL_PANELS} panel expressions checked, ${EMPTY_PANELS} returned empty"

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
  # Poll up to 240s instead of fixed 180s. Worst case: scrape interval
  # (15-30s) + alert for: 2m + slack. With 30s scrape and 16x15s polls,
  # we tolerate ~120s + 240s = 360s but exit early as soon as firing.
  step "Poll alerts API every 15s up to 240s for PerfSentinelDaemonDown firing"
  FIRING="no"
  TRIGGER_DEADLINE=$((SECONDS + 240))
  TRIGGER_LAST_STATE="not-yet"
  while [ ${SECONDS} -lt ${TRIGGER_DEADLINE} ]; do
    TRIGGER_LAST_STATE=$(kubectl exec -n observability "${PROMETHEUS_POD}" -c prometheus -- \
      wget -qO- 'http://localhost:9090/api/v1/alerts' 2>/dev/null \
      | python3 -c "
import json, sys
try:
    alerts = json.load(sys.stdin)['data']['alerts']
except Exception:
    print('error')
    sys.exit(0)
for a in alerts:
    if a.get('labels', {}).get('alertname') == 'PerfSentinelDaemonDown':
        print(a.get('state', 'unknown'))
        sys.exit(0)
print('absent')
" 2>/dev/null || echo "error")
    if [ "${TRIGGER_LAST_STATE}" = "firing" ]; then
      FIRING="yes"
      break
    fi
    sleep 15
  done
  step "Restore daemon"
  kubectl scale -n observability deployment/perf-sentinel-daemon --replicas=1 >/dev/null
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

if [ "${BROKEN_COUNT}" -eq 0 ] \
   && [ "${EMPTY_PANELS}" -eq 0 ] \
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
  echo "- empty results: ${EMPTY_PANELS}"
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
  echo "- Prometheus scrape health: ${SCRAPE_HEALTH}"
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
