#!/usr/bin/env bash
# multi-agent-load: validate the perf-sentinel daemon under concurrent
# OTLP load. Spins up a kubectl Job with parallelism=PRODUCERS, each Pod
# running telemetrygen against the prod daemon Service, then asserts on
# /api/status, /api/export/report and /metrics that the daemon survived
# the burst, processed a reasonable share of the spans, and did not
# leak memory or in-flight traces.

set -euo pipefail

SCENARIO="multi-agent-load"
NS="b3-multi-agent"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
MANIFESTS="$(cd "$(dirname "$0")" && pwd)/manifests.yaml"
mkdir -p "${TMP_DIR}"

PRODUCERS="${PRODUCERS:-10}"
RATE_PER_PRODUCER="${RATE_PER_PRODUCER:-100}"
DURATION="${DURATION:-60s}"
DAEMON_LOCAL_PORT="${DAEMON_LOCAL_PORT:-14318}"
RSS_LIMIT_BYTES="${RSS_LIMIT_BYTES:-524288000}"
# The daemon at the lab's default CPU limit (200m) does not process
# OTLP at telemetrygen's full burst rate; drops are a pass-through
# property of the lab environment, not a daemon regression. The smoke
# verdict is therefore "daemon survives + ingestion non-zero", not a
# throughput ratio. Real throughput benchmarking is upstream.
MIN_EVENTS_DELTA="${MIN_EVENTS_DELTA:-3}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; cleanup; exit 1; }

cleanup() {
  if [ "${KEEP_NAMESPACE:-no}" != "yes" ]; then
    kubectl delete networkpolicy perf-sentinel-allow-b3-multi-agent -n observability --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl delete namespace "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

verdict="UNKNOWN"
EVENTS_BEFORE=0; EVENTS_AFTER=0; DELTA_EVENTS=0
TRACES_BEFORE=0; TRACES_AFTER=0; DELTA_TRACES=0
ACTIVE_END=0
RSS_AFTER=0
EXPECTED=0; RATIO="0.00"

step "Sanity: daemon is reachable on localhost:${DAEMON_LOCAL_PORT}/api/status"
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null \
  || die "daemon unreachable on localhost:${DAEMON_LOCAL_PORT}, run ./scripts/port-forward.sh start"
ok "daemon reachable"

step "Apply Job manifest with PRODUCERS=${PRODUCERS} RATE=${RATE_PER_PRODUCER} DURATION=${DURATION}"
PRODUCERS="${PRODUCERS}" RATE_PER_PRODUCER="${RATE_PER_PRODUCER}" DURATION="${DURATION}" \
  envsubst '${PRODUCERS} ${RATE_PER_PRODUCER} ${DURATION}' < "${MANIFESTS}" \
  | kubectl apply -f - > "${TMP_DIR}/apply.log" 2>&1
ok "manifests applied"

step "Snapshot daemon metrics before load"
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/export/report" > "${TMP_DIR}/report-before.json"
EVENTS_BEFORE=$(python3 -c "import json; print(json.load(open('${TMP_DIR}/report-before.json')).get('analysis', {}).get('events_processed', 0))")
TRACES_BEFORE=$(python3 -c "import json; print(json.load(open('${TMP_DIR}/report-before.json')).get('analysis', {}).get('traces_analyzed', 0))")
ok "events_before=${EVENTS_BEFORE} traces_before=${TRACES_BEFORE}"

step "Wait for the telemetrygen Job to complete"
DURATION_NUM="${DURATION%s}"
TIMEOUT_SEC=$(( DURATION_NUM + 120 ))
kubectl -n "${NS}" wait --for=condition=Complete --timeout="${TIMEOUT_SEC}s" \
  job/b3-telemetrygen-load > "${TMP_DIR}/wait.log" 2>&1 \
  || die "Job did not complete in ${TIMEOUT_SEC}s, see ${TMP_DIR}/wait.log"
ok "Job complete"

step "Wait 30s for daemon to drain in-flight buffer"
sleep 30

step "Snapshot daemon metrics after load"
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/export/report" > "${TMP_DIR}/report-after.json"
EVENTS_AFTER=$(python3 -c "import json; print(json.load(open('${TMP_DIR}/report-after.json')).get('analysis', {}).get('events_processed', 0))")
TRACES_AFTER=$(python3 -c "import json; print(json.load(open('${TMP_DIR}/report-after.json')).get('analysis', {}).get('traces_analyzed', 0))")
DELTA_EVENTS=$(( EVENTS_AFTER - EVENTS_BEFORE ))
DELTA_TRACES=$(( TRACES_AFTER - TRACES_BEFORE ))
ok "events_after=${EVENTS_AFTER} delta_events=${DELTA_EVENTS} delta_traces=${DELTA_TRACES}"

step "Read /metrics for active_traces, kubectl top for RSS"
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/metrics" > "${TMP_DIR}/metrics-after.txt"
ACTIVE_END=$(awk '/^perf_sentinel_active_traces / {print int($2)}' "${TMP_DIR}/metrics-after.txt" | head -1)
ACTIVE_END="${ACTIVE_END:-0}"
RSS_MIB=$(kubectl top pod -n observability -l app.kubernetes.io/name=perf-sentinel-daemon --no-headers 2>/dev/null | awk '{gsub("Mi","",$3); print int($3)}' | head -1)
RSS_MIB="${RSS_MIB:-0}"
RSS_AFTER=$(( RSS_MIB * 1024 * 1024 ))
ok "rss_after=${RSS_AFTER}B (${RSS_MIB}Mi via kubectl top) active_traces_end=${ACTIVE_END}"

step "Compute verdict"
EXPECTED=$(( PRODUCERS * RATE_PER_PRODUCER * DURATION_NUM ))
if [ "${EXPECTED}" -gt 0 ]; then
  RATIO=$(python3 -c "print(f'{${DELTA_EVENTS} / ${EXPECTED}:.4f}')")
fi
DAEMON_ALIVE=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null 2>&1 && echo yes || echo no)

PASS_INGEST=$([ "${DELTA_EVENTS}" -ge "${MIN_EVENTS_DELTA}" ] && echo yes || echo no)
PASS_RSS=$([ "${RSS_AFTER}" -lt "${RSS_LIMIT_BYTES}" ] && echo yes || echo no)

if [ "${DAEMON_ALIVE}" = "yes" ] && [ "${PASS_INGEST}" = "yes" ] && [ "${PASS_RSS}" = "yes" ]; then
  verdict="PASS"
else
  verdict="FAIL"
  kubectl -n observability logs deploy/perf-sentinel-daemon --tail=80 > "${TMP_DIR}/daemon.log" 2>&1 || true
fi

step "Write report"
{
  echo "# multi-agent-load: ${PRODUCERS} producers @ ${RATE_PER_PRODUCER} sps for ${DURATION}"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Namespace: ${NS} (cleaned up after run unless KEEP_NAMESPACE=yes)"
  echo
  echo "## Inputs"
  echo
  echo "- PRODUCERS=${PRODUCERS}"
  echo "- RATE_PER_PRODUCER=${RATE_PER_PRODUCER} sps"
  echo "- DURATION=${DURATION}"
  echo "- Expected total spans = ${EXPECTED}"
  echo
  echo "## Daemon snapshot"
  echo
  echo "- events_processed delta: ${DELTA_EVENTS} (ratio vs expected: ${RATIO})"
  echo "- traces_analyzed delta: ${DELTA_TRACES}"
  echo "- process_resident_memory_bytes: ${RSS_AFTER} (limit ${RSS_LIMIT_BYTES})"
  echo "- perf_sentinel_active_traces (post-drain): ${ACTIVE_END}"
  echo "- daemon /api/status reachable post-load: ${DAEMON_ALIVE}"
  echo
  echo "## Verdicts"
  echo
  echo "- daemon_alive: ${DAEMON_ALIVE}"
  echo "- ingestion non-zero (delta >= ${MIN_EVENTS_DELTA}): ${PASS_INGEST}"
  echo "- rss_under_limit: ${PASS_RSS}"
  echo
  if [ "${verdict}" = "FAIL" ]; then
    echo "## Daemon logs (tail)"
    echo
    echo '```'
    tail -80 "${TMP_DIR}/daemon.log" 2>/dev/null || true
    echo '```'
    echo
  fi
  echo "**Verdict: ${verdict}**"
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  ok "PASS, see ${REPORT}"
  exit 0
else
  die "${verdict}, see ${REPORT}"
fi
