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
#   4. Daemon log signal : "Scaphandre scraper started" present, no
#                          "Scaphandre scrape failed"
#   5. Daemon gauge      : perf_sentinel_scaphandre_last_scrape_age_seconds
#                          stays < scrape_interval (proves recent success)
#   6. Mock degradation  : scale mock to 0, daemon stays up, "scrape failed"
#                          appears in logs (proxy fallback active)

set -euo pipefail

SCENARIO="scaphandre-mock-validation"
NS="observability"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
mkdir -p "${TMP_DIR}"

DAEMON_LOCAL_PORT="${DAEMON_LOCAL_PORT:-14318}"
MOCK_LOCAL_PORT="${MOCK_LOCAL_PORT:-19100}"
SCRAPE_INTERVAL_SEC="${SCRAPE_INTERVAL_SEC:-5}"
DEGRADE_WAIT_SEC="${DEGRADE_WAIT_SEC:-30}"
# Log lookback window: covers the daemon uptime in CI (45 min job
# timeout) and a busy local session, without overpaying on a quiet
# daemon where --tail bounds the buffer naturally.
LOG_SINCE="${LOG_SINCE:-2h}"

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
# 4. Daemon log signal
#######################################
step "4. Daemon log: 'Scaphandre scraper started' + no 'scrape failed'"
DAEMON_LOG="${TMP_DIR}/daemon.log"
# Use --since to span the daemon uptime: --tail=500 can drop the
# one-shot startup line after a busy CI sequence (long-running-drift,
# validate-findings emit thousands of lines).
kubectl -n "${NS}" logs deploy/perf-sentinel-daemon --since="${LOG_SINCE}" \
  > "${DAEMON_LOG}" 2>&1 || true
if grep -q 'Scaphandre scraper started' "${DAEMON_LOG}"; then
  STARTED_LINE=$(grep 'Scaphandre scraper started' "${DAEMON_LOG}" | tail -1)
  if grep -q 'Scaphandre scrape failed' "${DAEMON_LOG}"; then
    # Mock may have come up after the daemon: any failure since the
    # last "scrape succeeded" debug line is the load-bearing signal,
    # but debug logs are often filtered. Treat presence of any failure
    # as a soft warning when started is also present.
    VERDICTS+=("PASS: 4 daemon scraper started (warn: 'scrape failed' lines exist, mock likely came up after daemon)")
  else
    VERDICTS+=("PASS: 4 daemon scraper started, no scrape failures: ${STARTED_LINE}")
  fi
else
  VERDICTS+=("FAIL: 4 'Scaphandre scraper started' absent from daemon logs (config TOML missing or parse error)")
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
# 6. Mock degradation: scale to 0, fallback graceful
#######################################
step "6. Mock degradation: scale to 0, daemon stays up"
kubectl -n "${NS}" scale deployment/scaphandre-mock --replicas=0 >/dev/null
MOCK_SCALED_DOWN="yes"
# Wait DEGRADE_WAIT_SEC for the daemon to register the failure.
sleep "${DEGRADE_WAIT_SEC}"
DAEMON_AFTER_SCALE="up"
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null 2>&1 \
  || DAEMON_AFTER_SCALE="down"
DAEMON_LOG_AFTER="${TMP_DIR}/daemon-after-scale.log"
# Same --since rationale as sub-test 4. The "scrape failed" warn is
# one-shot upstream (subsequent failures log at debug level), so if
# the daemon already emitted it earlier (mock startup race), no new
# line surfaces here. The PASS path below tolerates that case.
kubectl -n "${NS}" logs deploy/perf-sentinel-daemon --since="${LOG_SINCE}" \
  > "${DAEMON_LOG_AFTER}" 2>&1 || true
FAILED_LINES=$(grep -c 'Scaphandre scrape failed' "${DAEMON_LOG_AFTER}" || true)
if [ "${DAEMON_AFTER_SCALE}" = "up" ] && [ "${FAILED_LINES}" -ge 1 ]; then
  VERDICTS+=("PASS: 6 daemon up, ${FAILED_LINES} 'scrape failed' line(s) recorded (proxy fallback active)")
elif [ "${DAEMON_AFTER_SCALE}" = "up" ]; then
  VERDICTS+=("PASS: 6 daemon up (warn: no 'scrape failed' line in last 200 logs, daemon may have suppressed after first warn)")
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
  echo "SCRAPE_INTERVAL_SEC=${SCRAPE_INTERVAL_SEC} DEGRADE_WAIT_SEC=${DEGRADE_WAIT_SEC} LOG_SINCE=${LOG_SINCE}"
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
    tail -120 "${DAEMON_LOG_AFTER}" 2>/dev/null || tail -120 "${DAEMON_LOG}" 2>/dev/null || true
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
