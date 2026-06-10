#!/usr/bin/env bash
# limit-service-cardinality: 1500+ distinct service.names against the
# daemon's hardcoded 1024-service metering cap.
#
# Asserts:
#   - perf_sentinel_service_io_ops_overflow_total climbs (0.8.7 counter:
#     ops beyond the cap are unattributed but no longer silent);
#   - exactly 1024 distinct service_io_ops_total series on /metrics;
#   - /metrics stays scrapeable: body < 1.5 MiB, curl wall time < 2s;
#   - ingestion keeps flowing, RSS < 230 MiB, zero pod restarts.
# LONG_RUN=1: 5000 services and a longer run; additionally expects
# correlator pair evictions (perf_sentinel_correlator_pairs_evicted_total).
set -euo pipefail

SCENARIO="limit-service-cardinality"
OBS_NS="observability"
DEPLOY="perf-sentinel-daemon"
DAEMON_SELECTOR="app.kubernetes.io/name=perf-sentinel-daemon"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
mkdir -p "${TMP_DIR}"

DAEMON_LOCAL_PORT="${DAEMON_LOCAL_PORT:-14318}"
ENDPOINT="http://localhost:${DAEMON_LOCAL_PORT}"
SERVICES="${SERVICES:-1500}"
TPS="${TPS:-80}"
DURATION="${DURATION:-240}"
RSS_LIMIT_BYTES="${RSS_LIMIT_BYTES:-241172480}"  # 230 MiB
if [ "${LONG_RUN:-0}" = "1" ]; then
  SERVICES=5000; DURATION=600
fi

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
color_yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
skip() { color_yellow "    skip: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

cleanup() {
  kubectl -n limit-testing delete job tracegen-cardinality --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

pf_restart() {
  pkill -f "kubectl.*port-forward.*${DEPLOY}" 2>/dev/null || true
  sleep 2
  "${REPO_ROOT}/scripts/port-forward.sh" start >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    curl -fsS "${ENDPOINT}/api/status" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}
metric_val() {
  awk -v m="$1" '$1==m {print int($2); found=1} END {if(!found) print 0}' "${TMP_DIR}/metrics.txt" | head -1
}
snapshot_metrics() { curl -fsS "${ENDPOINT}/metrics" > "${TMP_DIR}/metrics.txt"; }
daemon_restarts() {
  kubectl -n "${OBS_NS}" get pod -l "${DAEMON_SELECTOR}" \
    -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0
}

# =============================================================================
step "Preflight: fresh daemon process (cap state is process-lifetime), 0.8.7 counters"
if kubectl get pods -n shop --no-headers 2>/dev/null | grep -q .; then
  color_yellow "    warning: the shop fleet is running; for clean cardinality numbers tear it down (scripts/teardown-services.sh)"
fi
kubectl -n "${OBS_NS}" rollout restart deploy/"${DEPLOY}" >/dev/null
kubectl -n "${OBS_NS}" rollout status deploy/"${DEPLOY}" --timeout=180s >/dev/null || die "daemon rollout failed"
pf_restart || die "daemon unreachable after restart"
snapshot_metrics
grep -q "^# TYPE perf_sentinel_service_io_ops_overflow_total " "${TMP_DIR}/metrics.txt" \
  || die "service_io_ops_overflow_total absent (daemon is not 0.8.7? run scripts/seed-daemon-local.sh)"
RESTARTS_BEFORE="$(daemon_restarts)"
OVERFLOW_BEFORE="$(metric_val perf_sentinel_service_io_ops_overflow_total)"
EVICTED_BEFORE="$(metric_val perf_sentinel_correlator_pairs_evicted_total)"
ok "fresh daemon, overflow=${OVERFLOW_BEFORE}"

# =============================================================================
step "Load: ${SERVICES} services at ${TPS} tps for ${DURATION}s (n+1/clean mix)"
kubectl apply -f "${REPO_ROOT}/scenarios/limit-common/manifests.yaml" >/dev/null
kubectl apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: tracegen-cardinality
  namespace: limit-testing
spec:
  backoffLimit: 0
  template:
    metadata:
      labels: { app: tracegen }
    spec:
      restartPolicy: Never
      containers:
        - name: tracegen
          image: lab-tracegen:1
          imagePullPolicy: Never
          args:
            - "--endpoint=http://perf-sentinel-daemon.observability.svc.cluster.local:14318"
            - "--protocol=http-pb"
            - "--services=${SERVICES}"
            - "--service-prefix=card"
            - "--tps=${TPS}"
            - "--duration=${DURATION}"
            - "--mix=n_plus_one:50,clean:50"
          resources:
            requests: { cpu: 100m, memory: 64Mi }
            limits: { cpu: "1", memory: 192Mi }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: ["ALL"] }
EOF

# Poll while the Job runs: liveness + RSS ceiling.
POLLS=0; POLLS_OK=0; RSS_MAX=0
END=$(( $(date +%s) + DURATION + 90 ))
while [ "$(date +%s)" -lt "${END}" ]; do
  PHASE="$(kubectl -n limit-testing get job tracegen-cardinality -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "")"
  POLLS=$(( POLLS + 1 ))
  if snapshot_metrics 2>/dev/null; then
    POLLS_OK=$(( POLLS_OK + 1 ))
    RSS="$(metric_val process_resident_memory_bytes)"
    [ "${RSS}" -gt "${RSS_MAX}" ] && RSS_MAX="${RSS}"
  fi
  [ "${PHASE}" = "1" ] && break
  sleep 10
done
kubectl -n limit-testing wait --for=condition=complete "job/tracegen-cardinality" --timeout=120s >/dev/null 2>&1 \
  || die "tracegen job did not complete: $(kubectl -n limit-testing logs job/tracegen-cardinality --tail=5 2>/dev/null | tr '\n' ' ')"
GEN_REPORT="$(kubectl -n limit-testing logs job/tracegen-cardinality --tail=1)"
ok "job done: ${GEN_REPORT}"

# =============================================================================
step "Asserts: overflow counter, exact 1024 series, /metrics scrape envelope"
sleep 5
SCRAPE_START="$(python3 -c 'import time;print(time.time())')"
snapshot_metrics || die "/metrics unreachable after the load"
SCRAPE_SECS="$(python3 -c "import time;print('%.2f' % (time.time() - ${SCRAPE_START}))")"
METRICS_BYTES="$(wc -c < "${TMP_DIR}/metrics.txt" | tr -d ' ')"
SERIES_COUNT="$(grep -c '^perf_sentinel_service_io_ops_total{' "${TMP_DIR}/metrics.txt" || echo 0)"
OVERFLOW_AFTER="$(metric_val perf_sentinel_service_io_ops_overflow_total)"
EVICTED_AFTER="$(metric_val perf_sentinel_correlator_pairs_evicted_total)"
D_OVERFLOW=$(( OVERFLOW_AFTER - OVERFLOW_BEFORE ))
RESTARTS_AFTER="$(daemon_restarts)"

[ "${D_OVERFLOW}" -gt 0 ] || die "overflow counter did not move with ${SERVICES} services (cap is 1024)"
[ "${SERIES_COUNT}" -eq 1024 ] || die "expected exactly 1024 service series, got ${SERIES_COUNT}"
[ "${METRICS_BYTES}" -le 1572864 ] || die "/metrics body is ${METRICS_BYTES} bytes (> 1.5 MiB)"
python3 -c "exit(0 if float('${SCRAPE_SECS}') < 2.0 else 1)" || die "/metrics scrape took ${SCRAPE_SECS}s (>= 2s)"
[ "${RSS_MAX}" -le "${RSS_LIMIT_BYTES}" ] || die "RSS peaked at $(( RSS_MAX / 1048576 )) MiB (> 230 MiB)"
[ "${RESTARTS_AFTER}" = "${RESTARTS_BEFORE}" ] || die "daemon restarted (${RESTARTS_BEFORE} -> ${RESTARTS_AFTER})"
[ "${POLLS_OK}" -ge $(( POLLS * 7 / 10 )) ] || die "daemon reachable on only ${POLLS_OK}/${POLLS} polls"
ok "overflow +${D_OVERFLOW}, series=1024, /metrics ${METRICS_BYTES}B in ${SCRAPE_SECS}s, rss_max=$(( RSS_MAX / 1048576 )) MiB"

EVICT_NOTE="n/a (fast mode)"
if [ "${LONG_RUN:-0}" = "1" ]; then
  D_EVICTED=$(( EVICTED_AFTER - EVICTED_BEFORE ))
  [ "${D_EVICTED}" -gt 0 ] || die "deep mode expected correlator pair evictions, got 0"
  EVICT_NOTE="+${D_EVICTED}"
  ok "correlator pair evictions ${EVICT_NOTE}"
fi

verdict="PASS"
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "| check | value |"
  echo "|---|---|"
  echo "| services sent | ${SERVICES} |"
  echo "| generator | ${GEN_REPORT} |"
  echo "| service_io_ops_overflow delta | +${D_OVERFLOW} |"
  echo "| service series on /metrics | ${SERIES_COUNT} (cap 1024) |"
  echo "| /metrics size / scrape time | ${METRICS_BYTES} B / ${SCRAPE_SECS}s |"
  echo "| rss max | $(( RSS_MAX / 1048576 )) MiB |"
  echo "| correlator evictions | ${EVICT_NOTE} |"
  echo "| restarts | ${RESTARTS_BEFORE} -> ${RESTARTS_AFTER} |"
  echo "| liveness polls | ${POLLS_OK}/${POLLS} |"
  echo ""
  echo "Verdict: **${verdict}**"
} > "${REPORT}"
color_green "PASS — report at ${REPORT}"
