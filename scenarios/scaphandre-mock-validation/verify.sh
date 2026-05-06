#!/usr/bin/env bash
# scaphandre-mock-validation: end-to-end validation of the Scaphandre
# scrape path. RAPL is not accessible on Apple Silicon nor on most
# cloud runners, so the lab ships a Python stdlib mock at
# `manifests/scaphandre-mock.yaml`. This scenario asserts the daemon
# loads `[green.scaphandre]` from its ConfigMap, spawns the scraper
# task, scrapes the mock successfully, and falls back gracefully when
# the mock is taken down.
#
# Sub-tests:
#   1. Sanity            : daemon /api/status + mock pod Running
#   2. Mock /metrics     : 5 lines of scaph_process_power_consumption_microwatts
#   3. Determinism       : 2 consecutive scrapes return identical power values
#   4. Counter success   : scrape_total{status=success} delta over scrape_interval
#   5. Daemon gauge      : perf_sentinel_scaphandre_last_scrape_age_seconds
#                          stays < scrape_interval (proves recent success)
#   6. Counter fail      : scale mock to 0, scrape_failed_total{reason in
#                          unreachable, timeout} delta proves the daemon
#                          classified the outage as a connectivity failure

set -euo pipefail

SCENARIO="scaphandre-mock-validation"
NS="observability"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
mkdir -p "${TMP_DIR}"

DAEMON_LOCAL_PORT="${DAEMON_LOCAL_PORT:-14318}"
MOCK_LOCAL_PORT="${MOCK_LOCAL_PORT:-19100}"
SCRAPE_INTERVAL_SEC="${SCRAPE_INTERVAL_SEC:-5}"
# Must exceed the mock's terminationGracePeriodSeconds (30s on
# scaphandre-mock) plus at least one scrape_interval. The Python stdlib
# HTTP server ignores SIGTERM, so it keeps answering until the SIGKILL
# at the end of the grace period — sampling earlier than 35s would
# capture the pod still responding, not a truly-dead endpoint.
DEGRADE_WAIT_SEC="${DEGRADE_WAIT_SEC:-45}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

VERDICTS=()
MOCK_PF_PID=""
MOCK_SCALED_DOWN="no"

cleanup() {
  if [ -n "${MOCK_PF_PID}" ] && kill -0 "${MOCK_PF_PID}" 2>/dev/null; then
    kill "${MOCK_PF_PID}" 2>/dev/null || true
  fi
  if [ "${MOCK_SCALED_DOWN}" = "yes" ]; then
    kubectl -n "${NS}" scale deployment/scaphandre-mock --replicas=1 >/dev/null 2>&1 || true
    kubectl -n "${NS}" rollout status deployment/scaphandre-mock --timeout=60s >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

mock_pf_start() {
  kubectl -n "${NS}" port-forward svc/scaphandre-mock \
    "${MOCK_LOCAL_PORT}:9100" > "${TMP_DIR}/mock-pf.log" 2>&1 &
  MOCK_PF_PID=$!
  for _ in $(seq 1 30); do
    if curl -fsS "http://localhost:${MOCK_LOCAL_PORT}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

mock_pf_stop() {
  if [ -n "${MOCK_PF_PID}" ] && kill -0 "${MOCK_PF_PID}" 2>/dev/null; then
    kill "${MOCK_PF_PID}" 2>/dev/null || true
    wait "${MOCK_PF_PID}" 2>/dev/null || true
  fi
  MOCK_PF_PID=""
}

# Read perf_sentinel_scaphandre_last_scrape_age_seconds from the daemon
# /metrics. Prints the float value, or MISSING if the gauge is absent
# (build without the Scaphandre module).
gauge_scrape_age() {
  local body val
  body=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/metrics" 2>/dev/null) || body=""
  val=$(printf '%s\n' "${body}" | awk '/^perf_sentinel_scaphandre_last_scrape_age_seconds[ {]/ {print $2; exit}')
  if [ -z "${val}" ]; then
    printf 'MISSING\n'
  else
    printf '%s\n' "${val}"
  fi
}

# Read a Prometheus counter sample value from the daemon /metrics,
# matching on metric name plus a single label=value pair. Counters are
# pre-warmed at daemon startup so a missing sample is a real anomaly
# (build without Scaphandre module).
counter_value() {
  local metric_name="$1"
  local label_name="$2"
  local label_value="$3"
  local body val
  body=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/metrics" 2>/dev/null) || body=""
  val=$(printf '%s\n' "${body}" | awk -v m="${metric_name}" -v ln="${label_name}" -v lv="${label_value}" '
    $0 ~ "^"m"\\{" {
      pat = ln "=\"" lv "\""
      if ($0 ~ pat) { print $NF; exit }
    }
  ')
  if [ -z "${val}" ]; then printf '0\n'; else printf '%s\n' "${val}"; fi
}

#######################################
# 1. Sanity
#######################################
step "1. Sanity: daemon + scaphandre-mock pod"
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null \
  || die "daemon unreachable on localhost:${DAEMON_LOCAL_PORT}, run ./scripts/port-forward.sh start"
MOCK_POD=$(kubectl -n "${NS}" get pod \
  -l app.kubernetes.io/name=scaphandre-mock \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "${MOCK_POD}" ]; then
  die "no Running scaphandre-mock pod, run: make seed-scaphandre-mock"
fi
ok "daemon up, mock pod=${MOCK_POD}"

#######################################
# 2. Mock /metrics shape
#######################################
step "2. Mock /metrics format"
if ! mock_pf_start; then
  VERDICTS+=("FAIL: 2 mock /healthz unreachable via port-forward (see ${TMP_DIR}/mock-pf.log)")
else
  curl -fsS "http://localhost:${MOCK_LOCAL_PORT}/metrics" > "${TMP_DIR}/scrape-1.txt" \
    || { VERDICTS+=("FAIL: 2 GET /metrics on mock failed"); }
  if [ -s "${TMP_DIR}/scrape-1.txt" ]; then
    GAUGE_LINES=$(grep -c '^scaph_process_power_consumption_microwatts{' "${TMP_DIR}/scrape-1.txt" || true)
    HAS_HELP=$(grep -c '^# HELP scaph_process_power_consumption_microwatts' "${TMP_DIR}/scrape-1.txt" || true)
    HAS_TYPE=$(grep -c '^# TYPE scaph_process_power_consumption_microwatts gauge' "${TMP_DIR}/scrape-1.txt" || true)
    if [ "${GAUGE_LINES}" -ge 5 ] && [ "${HAS_HELP}" -eq 1 ] && [ "${HAS_TYPE}" -eq 1 ]; then
      VERDICTS+=("PASS: 2 mock /metrics OK (lines=${GAUGE_LINES}, HELP/TYPE present)")
    else
      VERDICTS+=("FAIL: 2 mock /metrics shape (lines=${GAUGE_LINES} expected>=5, help=${HAS_HELP}, type=${HAS_TYPE})")
    fi
  fi
fi

#######################################
# 3. Determinism: a second scrape returns identical values
#######################################
step "3. Determinism (2 consecutive scrapes)"
if [ -s "${TMP_DIR}/scrape-1.txt" ]; then
  sleep 1
  curl -fsS "http://localhost:${MOCK_LOCAL_PORT}/metrics" > "${TMP_DIR}/scrape-2.txt" || true
  # Strip HELP/TYPE comments, the gauge lines must match byte-for-byte.
  grep '^scaph_process_power_consumption_microwatts{' "${TMP_DIR}/scrape-1.txt" | sort > "${TMP_DIR}/scrape-1.sorted"
  grep '^scaph_process_power_consumption_microwatts{' "${TMP_DIR}/scrape-2.txt" | sort > "${TMP_DIR}/scrape-2.sorted"
  if diff -q "${TMP_DIR}/scrape-1.sorted" "${TMP_DIR}/scrape-2.sorted" >/dev/null 2>&1; then
    VERDICTS+=("PASS: 3 deterministic (2 scrapes return identical power values)")
  else
    VERDICTS+=("FAIL: 3 non-deterministic (diff between scrapes, see ${TMP_DIR})")
  fi
else
  VERDICTS+=("FAIL: 3 skipped (scrape-1 was empty)")
fi
mock_pf_stop

#######################################
# 4. Daemon counter: scrape success delta
#######################################
step "4. Daemon /metrics counter: scrape_total{status=success} delta"
SUCCESS_BEFORE=$(counter_value perf_sentinel_scaphandre_scrape_total status success)
sleep $(( SCRAPE_INTERVAL_SEC + 1 ))
SUCCESS_AFTER=$(counter_value perf_sentinel_scaphandre_scrape_total status success)
SUCCESS_DELTA_POS=$(awk -v a="${SUCCESS_AFTER}" -v b="${SUCCESS_BEFORE}" 'BEGIN{print (a+0 > b+0) ? 1 : 0}')

if [ "${SUCCESS_DELTA_POS}" = "1" ]; then
  VERDICTS+=("PASS: 4 scrape_total{status=success} before=${SUCCESS_BEFORE} after=${SUCCESS_AFTER} (scraper active)")
else
  VERDICTS+=("FAIL: 4 scrape_total{status=success} before=${SUCCESS_BEFORE} after=${SUCCESS_AFTER} (no positive delta over $((SCRAPE_INTERVAL_SEC+1))s, scraper inactive)")
fi

#######################################
# 5. Daemon gauge: perf_sentinel_scaphandre_last_scrape_age_seconds
#######################################
step "5. Daemon /metrics gauge: scrape age within scrape_interval"
sleep $(( SCRAPE_INTERVAL_SEC + 1 ))
V1=$(gauge_scrape_age)
sleep $(( SCRAPE_INTERVAL_SEC + 1 ))
V2=$(gauge_scrape_age)
if [ "${V1}" = "MISSING" ] && [ "${V2}" = "MISSING" ]; then
  VERDICTS+=("FAIL: 5 gauge perf_sentinel_scaphandre_last_scrape_age_seconds absent on both polls (build without Scaphandre module)")
else
  # The gauge resets to 0 on every successful scrape and grows in real
  # time between scrapes. At least one of two samples taken
  # scrape_interval+1 seconds apart must be < scrape_interval+2 to
  # prove a recent scrape succeeded. Leave a 2s margin for sample
  # jitter against the daemon's tokio ticker.
  THRESHOLD=$(( SCRAPE_INTERVAL_SEC + 2 ))
  PASS_GAUGE="no"
  for V in "${V1}" "${V2}"; do
    if [ "${V}" != "MISSING" ]; then
      # awk float compare (bash arithmetic is integer-only).
      LT=$(awk -v v="${V}" -v t="${THRESHOLD}" 'BEGIN{print (v+0 < t+0) ? 1 : 0}')
      if [ "${LT}" = "1" ]; then
        PASS_GAUGE="yes"
      fi
    fi
  done
  if [ "${PASS_GAUGE}" = "yes" ]; then
    VERDICTS+=("PASS: 5 gauge V1=${V1}s V2=${V2}s (one < ${THRESHOLD}s, scrape active)")
  else
    VERDICTS+=("FAIL: 5 gauge V1=${V1}s V2=${V2}s (both >= ${THRESHOLD}s, scraper hung or unreachable)")
  fi
fi

#######################################
# 6. Mock degradation: counter-delta on failed{reason in unreachable,timeout}
#######################################
# Either reason is a valid classification of "service has no endpoints"
# depending on the cluster network stack: Cilium drops silently → timeout
# at the daemon's reqwest layer; kube-proxy iptables rejects with ICMP
# → unreachable. Asserting on the union still rules out the 5 other reasons
# (http_error, body_read_error, body_too_large, request_error, invalid_utf8)
# which would all be upstream bugs in this fault model.
step "6. Mock degradation: scale to 0, daemon classifies as unreachable+timeout"
UNREACH_BEFORE=$(counter_value perf_sentinel_scaphandre_scrape_failed_total reason unreachable)
TIMEOUT_BEFORE=$(counter_value perf_sentinel_scaphandre_scrape_failed_total reason timeout)

kubectl -n "${NS}" scale deployment/scaphandre-mock --replicas=0 >/dev/null
MOCK_SCALED_DOWN="yes"
# With DEGRADE_WAIT_SEC=45s default and scrape_interval=5s, the daemon
# observes ~3 failed scrapes after the mock's SIGKILL at t=30s. Increase
# DEGRADE_WAIT_SEC if the mock's terminationGracePeriodSeconds rises.
sleep "${DEGRADE_WAIT_SEC}"

DAEMON_AFTER_SCALE="up"
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null 2>&1 \
  || DAEMON_AFTER_SCALE="down"

UNREACH_AFTER=$(counter_value perf_sentinel_scaphandre_scrape_failed_total reason unreachable)
TIMEOUT_AFTER=$(counter_value perf_sentinel_scaphandre_scrape_failed_total reason timeout)
UNAVAIL_DELTA_POS=$(awk -v ua="${UNREACH_AFTER}" -v ub="${UNREACH_BEFORE}" \
                       -v ta="${TIMEOUT_AFTER}" -v tb="${TIMEOUT_BEFORE}" \
                       'BEGIN{print ((ua+ta) > (ub+tb)) ? 1 : 0}')

if [ "${DAEMON_AFTER_SCALE}" = "up" ] && [ "${UNAVAIL_DELTA_POS}" = "1" ]; then
  VERDICTS+=("PASS: 6 daemon up, unreachable+timeout before=(${UNREACH_BEFORE},${TIMEOUT_BEFORE}) after=(${UNREACH_AFTER},${TIMEOUT_AFTER}) (fallback active, mock unavailability classified)")
elif [ "${DAEMON_AFTER_SCALE}" = "up" ]; then
  VERDICTS+=("FAIL: 6 daemon up but no unreachable+timeout delta before=(${UNREACH_BEFORE},${TIMEOUT_BEFORE}) after=(${UNREACH_AFTER},${TIMEOUT_AFTER}) (mock outage classified as another reason, check /metrics)")
else
  VERDICTS+=("FAIL: 6 daemon /api/status down after mock scale to 0")
fi
# Cleanup is performed by the trap.

#######################################
# Aggregate verdicts
#######################################
step "Aggregate verdicts"
verdict="PASS"
for v in "${VERDICTS[@]}"; do
  echo "    ${v}"
  if echo "${v}" | grep -q "^FAIL"; then
    verdict="FAIL"
  fi
done

step "Write report"
{
  echo "# scaphandre-mock-validation"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "DAEMON_LOCAL_PORT=${DAEMON_LOCAL_PORT} MOCK_LOCAL_PORT=${MOCK_LOCAL_PORT}"
  echo "SCRAPE_INTERVAL_SEC=${SCRAPE_INTERVAL_SEC} DEGRADE_WAIT_SEC=${DEGRADE_WAIT_SEC}"
  echo
  echo "## Gauge readings"
  echo
  echo "- perf_sentinel_scaphandre_last_scrape_age_seconds V1=${V1:-N/A}s V2=${V2:-N/A}s"
  echo
  echo "## Sub-test verdicts"
  echo
  for v in "${VERDICTS[@]}"; do
    echo "- ${v}"
  done
  echo
  if [ "${verdict}" = "FAIL" ]; then
    echo "## Daemon logs (tail at end of run)"
    echo
    echo '```'
    kubectl -n "${NS}" logs deploy/perf-sentinel-daemon --tail=120 2>/dev/null || true
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
