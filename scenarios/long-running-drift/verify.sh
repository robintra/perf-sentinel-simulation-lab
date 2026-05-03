#!/usr/bin/env bash
# long-running-drift: detect slow memory leaks and FD leaks invisible
# on short runs. Continuous traffic at TRAFFIC_MULTIPLIER x baseline,
# periodic sampling of RSS/FDs/active_traces, drift comparison between
# the warm-up window [10-30 %] and the tail window [70-100 %] of the
# run. Default 2h, LONG_RUN=1 stretches to 24h.
#
# Inputs:
#   DURATION_HOURS         (default 2)        run length in hours
#   SAMPLE_INTERVAL        (default 300)      seconds between samples
#   TRAFFIC_MULTIPLIER     (default 10)       multiplies the base 100 sps
#   LONG_RUN=1             override -> 24h, multiplier 1, sample 900s
#   DAEMON_LOCAL_PORT      (default 14318)    daemon /metrics + /api on this local port
#   DRIFT_PCT_LIMIT        (default 10)       fail threshold on RSS drift %

set -euo pipefail

SCENARIO="long-running-drift"
NS="b3-drift"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
MANIFESTS="$(cd "$(dirname "$0")" && pwd)/manifests.yaml"
mkdir -p "${TMP_DIR}"

DURATION_HOURS="${DURATION_HOURS:-2}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-300}"
TRAFFIC_MULTIPLIER="${TRAFFIC_MULTIPLIER:-10}"
DAEMON_LOCAL_PORT="${DAEMON_LOCAL_PORT:-14318}"
DRIFT_PCT_LIMIT="${DRIFT_PCT_LIMIT:-10}"

if [ "${LONG_RUN:-0}" = "1" ]; then
  DURATION_HOURS=24
  SAMPLE_INTERVAL=900
  TRAFFIC_MULTIPLIER=1
fi

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; cleanup; exit 1; }

cleanup() {
  if [ "${KEEP_NAMESPACE:-no}" != "yes" ]; then
    kubectl delete networkpolicy perf-sentinel-allow-b3-drift -n observability --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl delete namespace "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

verdict="UNKNOWN"
DRIFT_RATE=$(( 100 * TRAFFIC_MULTIPLIER ))
DRIFT_DURATION="${DURATION_HOURS}h"
SAMPLES_FILE="${TMP_DIR}/drift-samples.tsv"

step "Sanity: daemon reachable on localhost:${DAEMON_LOCAL_PORT}"
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null \
  || die "daemon unreachable on localhost:${DAEMON_LOCAL_PORT}, run ./scripts/port-forward.sh start"
ok "daemon reachable"

step "Apply Job manifest (rate=${DRIFT_RATE}sps, duration=${DRIFT_DURATION})"
DRIFT_RATE="${DRIFT_RATE}" DRIFT_DURATION="${DRIFT_DURATION}" \
  envsubst '${DRIFT_RATE} ${DRIFT_DURATION}' < "${MANIFESTS}" \
  | kubectl apply -f - > "${TMP_DIR}/apply.log" 2>&1
ok "manifests applied"

step "Sampling loop: ${DURATION_HOURS}h, every ${SAMPLE_INTERVAL}s"
TOTAL_SECONDS=$(python3 -c "print(int(float(${DURATION_HOURS}) * 3600))")
TOTAL_SAMPLES=$(( TOTAL_SECONDS / SAMPLE_INTERVAL ))
[ "${TOTAL_SAMPLES}" -lt 4 ] && TOTAL_SAMPLES=4
echo -e "ts\trss_bytes\tfds\tactive_traces" > "${SAMPLES_FILE}"

START_TS=$(date +%s)
for i in $(seq 1 "${TOTAL_SAMPLES}"); do
  TS=$(date +%s)
  METRICS=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/metrics" 2>/dev/null || echo "")
  if [ -z "${METRICS}" ]; then
    echo -e "${TS}\t0\t0\t0" >> "${SAMPLES_FILE}"
  else
    RSS=$(echo "${METRICS}" | awk '/^process_resident_memory_bytes / {print int($2)}' | head -1)
    FDS=$(echo "${METRICS}" | awk '/^process_open_fds / {print int($2)}' | head -1)
    ACTIVE=$(echo "${METRICS}" | awk '/^perf_sentinel_active_traces / {print int($2)}' | head -1)
    echo -e "${TS}\t${RSS:-0}\t${FDS:-0}\t${ACTIVE:-0}" >> "${SAMPLES_FILE}"
  fi
  echo "    sample ${i}/${TOTAL_SAMPLES}: $(tail -1 "${SAMPLES_FILE}")"
  if [ "${i}" -lt "${TOTAL_SAMPLES}" ]; then
    sleep "${SAMPLE_INTERVAL}"
  fi
done
END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))
ok "${TOTAL_SAMPLES} samples collected in ${ELAPSED}s"

step "Compute drift between warm window [10-30 %] and tail window [70-100 %]"
ANALYSIS=$(python3 - "${SAMPLES_FILE}" <<'PYEOF'
import sys, statistics
path = sys.argv[1]
rows = []
with open(path) as fh:
    next(fh)
    for line in fh:
        parts = line.strip().split("\t")
        if len(parts) >= 4:
            rows.append([int(x) for x in parts[:4]])
n = len(rows)
if n < 4:
    print("0\t0\t0\t0\t0\t0\t0\t0\tinsufficient_samples")
    sys.exit(0)
warm = rows[max(1, n // 10):max(2, (3 * n) // 10) or 2]
tail = rows[max(2, (7 * n) // 10):]
def avg(seq, idx):
    vals = [r[idx] for r in seq]
    return statistics.mean(vals) if vals else 0.0
warm_rss = avg(warm, 1); tail_rss = avg(tail, 1)
warm_fds = avg(warm, 2); tail_fds = avg(tail, 2)
warm_at  = avg(warm, 3); tail_at  = avg(tail, 3)
drift_pct = ((tail_rss - warm_rss) * 100.0 / warm_rss) if warm_rss > 0 else 0.0
fds_delta = tail_fds - warm_fds
at_delta  = tail_at - warm_at
print(f"{int(warm_rss)}\t{int(tail_rss)}\t{drift_pct:.2f}\t{int(warm_fds)}\t{int(tail_fds)}\t{int(fds_delta)}\t{int(warm_at)}\t{int(tail_at)}\tok")
PYEOF
)
WARM_RSS=$(echo "${ANALYSIS}" | cut -f1)
TAIL_RSS=$(echo "${ANALYSIS}" | cut -f2)
DRIFT_PCT=$(echo "${ANALYSIS}" | cut -f3)
WARM_FDS=$(echo "${ANALYSIS}" | cut -f4)
TAIL_FDS=$(echo "${ANALYSIS}" | cut -f5)
FDS_DELTA=$(echo "${ANALYSIS}" | cut -f6)
WARM_AT=$(echo "${ANALYSIS}" | cut -f7)
TAIL_AT=$(echo "${ANALYSIS}" | cut -f8)
STATUS=$(echo "${ANALYSIS}" | cut -f9)
ok "drift_pct=${DRIFT_PCT}% fds_delta=${FDS_DELTA} active_traces_delta=$((TAIL_AT - WARM_AT))"

DAEMON_ALIVE=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null 2>&1 && echo yes || echo no)
PASS_DRIFT=$(python3 -c "print('yes' if abs(float('${DRIFT_PCT}')) < ${DRIFT_PCT_LIMIT} else 'no')")
PASS_FDS=$(python3 -c "print('yes' if abs(${FDS_DELTA}) < 5 else 'no')")
PASS_AT=$(python3 -c "print('yes' if (${TAIL_AT} - ${WARM_AT}) < max(50, ${WARM_AT}) else 'no')")

if [ "${STATUS}" = "ok" ] \
   && [ "${DAEMON_ALIVE}" = "yes" ] \
   && [ "${PASS_DRIFT}" = "yes" ] \
   && [ "${PASS_FDS}" = "yes" ] \
   && [ "${PASS_AT}" = "yes" ]; then
  verdict="PASS"
else
  verdict="FAIL"
  kubectl -n observability logs deploy/perf-sentinel-daemon --tail=80 > "${TMP_DIR}/daemon.log" 2>&1 || true
fi

step "Write report"
{
  echo "# long-running-drift: ${DURATION_HOURS}h at ${TRAFFIC_MULTIPLIER}x base traffic"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Namespace: ${NS} (cleaned up after run unless KEEP_NAMESPACE=yes)"
  echo
  echo "## Inputs"
  echo
  echo "- DURATION_HOURS=${DURATION_HOURS}"
  echo "- SAMPLE_INTERVAL=${SAMPLE_INTERVAL}s"
  echo "- TRAFFIC_MULTIPLIER=${TRAFFIC_MULTIPLIER} (rate=${DRIFT_RATE}sps)"
  echo "- DRIFT_PCT_LIMIT=${DRIFT_PCT_LIMIT}"
  echo "- Samples collected: ${TOTAL_SAMPLES} (status: ${STATUS})"
  echo
  echo "## Windows"
  echo
  echo "- warm window [10-30 %]: rss=${WARM_RSS}B fds=${WARM_FDS} active_traces=${WARM_AT}"
  echo "- tail window [70-100 %]: rss=${TAIL_RSS}B fds=${TAIL_FDS} active_traces=${TAIL_AT}"
  echo "- drift RSS: ${DRIFT_PCT}%"
  echo "- drift FDs: ${FDS_DELTA}"
  echo "- drift active_traces: $((TAIL_AT - WARM_AT))"
  echo
  echo "## Verdicts"
  echo
  echo "- daemon alive: ${DAEMON_ALIVE}"
  echo "- drift_rss < ${DRIFT_PCT_LIMIT}%: ${PASS_DRIFT}"
  echo "- fds stable (delta < 5): ${PASS_FDS}"
  echo "- active_traces not monotonically growing: ${PASS_AT}"
  echo
  echo "Samples TSV: ${SAMPLES_FILE}"
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
