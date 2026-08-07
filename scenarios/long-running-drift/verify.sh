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
NS="long-running-drift"
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
    kubectl delete networkpolicy perf-sentinel-allow-long-running-drift -n observability --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl delete namespace "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

verdict="UNKNOWN"
EVENTS_BEFORE=0; EVENTS_AFTER=0; DELTA_EVENTS=0
DRIFT_RATE=$(( 100 * TRAFFIC_MULTIPLIER ))
# Convert fractional hours to integer seconds. telemetrygen accepts Go
# duration strings like "300s", but rejects fractional hour notation
# like "0.083h", which broke the 5-min CI smoke profile until the
# format was switched to seconds.
DRIFT_DURATION_SEC=$(python3 -c "print(int(float(${DURATION_HOURS}) * 3600))")
DRIFT_DURATION="${DRIFT_DURATION_SEC}s"
SAMPLES_FILE="${TMP_DIR}/drift-samples.tsv"

step "Sanity: daemon reachable on localhost:${DAEMON_LOCAL_PORT}"
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null \
  || die "daemon unreachable on localhost:${DAEMON_LOCAL_PORT}, run ./scripts/port-forward.sh start"
ok "daemon reachable"

EVENTS_BEFORE=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/export/report" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('analysis', {}).get('events_processed', 0))")
ok "events_before=${EVENTS_BEFORE}"

step "Apply Job manifest (rate=${DRIFT_RATE}sps, duration=${DRIFT_DURATION})"
# shellcheck disable=SC2016
# Single quotes around the variable list are intentional, see
# multi-agent-load/verify.sh for the same rationale.
DRIFT_RATE="${DRIFT_RATE}" DRIFT_DURATION="${DRIFT_DURATION}" \
  envsubst '${DRIFT_RATE} ${DRIFT_DURATION}' < "${MANIFESTS}" \
  | kubectl apply -f - > "${TMP_DIR}/apply.log" 2>&1
ok "manifests applied"

step "Sampling loop: ${DURATION_HOURS}h (${DRIFT_DURATION_SEC}s), every ${SAMPLE_INTERVAL}s"
TOTAL_SAMPLES=$(( DRIFT_DURATION_SEC / SAMPLE_INTERVAL ))
[ "${TOTAL_SAMPLES}" -lt 4 ] && TOTAL_SAMPLES=4
echo -e "ts\trss_bytes\tfds\tactive_traces" > "${SAMPLES_FILE}"

START_TS=$(date +%s)
for i in $(seq 1 "${TOTAL_SAMPLES}"); do
  TS=$(date +%s)
  METRICS=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/metrics" 2>/dev/null || echo "")
  # 0.5.19+ exposes process_resident_memory_bytes and process_open_fds via
  # the prometheus client process collector. On older daemons (or builds
  # where the collector is cfg-gated off) these are absent, fall back to
  # `kubectl top pod` for RSS in MiB granularity and leave FDs at 0.
  # Feed METRICS via a here-string, not `echo ... | awk`: awk's early `exit`
  # closes the pipe, and once /metrics grows past the ~64 KB pipe buffer the
  # echo builtin takes a SIGPIPE that, under `set -o pipefail`, aborts the run.
  RSS=$(awk '/^process_resident_memory_bytes / {print int($2); exit}' <<<"${METRICS}")
  FDS=$(awk '/^process_open_fds / {print int($2); exit}' <<<"${METRICS}")
  if [ -z "${RSS}" ]; then
    RSS_MIB=$(kubectl top pod -n observability -l app.kubernetes.io/name=perf-sentinel-daemon --no-headers 2>/dev/null | awk '{gsub("Mi","",$3); print int($3); exit}')
    RSS=$(( ${RSS_MIB:-0} * 1024 * 1024 ))
  fi
  FDS="${FDS:-0}"
  ACTIVE=$(awk '/^perf_sentinel_active_traces / {print int($2); exit}' <<<"${METRICS}")
  echo -e "${TS}\t${RSS:-0}\t${FDS}\t${ACTIVE:-0}" >> "${SAMPLES_FILE}"
  echo "    sample ${i}/${TOTAL_SAMPLES}: $(tail -1 "${SAMPLES_FILE}")"
  if [ "${i}" -lt "${TOTAL_SAMPLES}" ]; then
    sleep "${SAMPLE_INTERVAL}"
  fi
done
END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))
ok "${TOTAL_SAMPLES} samples collected in ${ELAPSED}s"

EVENTS_AFTER=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/export/report" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('analysis', {}).get('events_processed', 0))")
DELTA_EVENTS=$(( EVENTS_AFTER - EVENTS_BEFORE ))
ok "events_after=${EVENTS_AFTER} delta_events=${DELTA_EVENTS}"

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
PASS_INGEST=$([ "${DELTA_EVENTS}" -gt 0 ] && echo yes || echo no)
PASS_DRIFT=$(python3 -c "print('yes' if abs(float('${DRIFT_PCT}')) < ${DRIFT_PCT_LIMIT} else 'no')")
PASS_AT=$(python3 -c "print('yes' if (${TAIL_AT} - ${WARM_AT}) < max(50, ${WARM_AT}) else 'no')")

# FDs leak gate fires only when the 0.5.19 surface populates the column.
# On 0.5.18 fallback the column stays 0 and the gate is reported skip.
if [ "${WARM_FDS}" -gt 0 ] || [ "${TAIL_FDS}" -gt 0 ]; then
  PASS_FDS=$([ "${FDS_DELTA}" -lt 50 ] && echo yes || echo no)
else
  PASS_FDS=skip
fi

if [ "${STATUS}" = "ok" ] \
   && [ "${DAEMON_ALIVE}" = "yes" ] \
   && [ "${PASS_INGEST}" = "yes" ] \
   && [ "${PASS_DRIFT}" = "yes" ] \
   && [ "${PASS_AT}" = "yes" ] \
   && [ "${PASS_FDS}" != "no" ]; then
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
  echo "- analyzable traffic processed (events delta > 0): ${PASS_INGEST} (${DELTA_EVENTS})"
  echo "- drift_rss < ${DRIFT_PCT_LIMIT}%: ${PASS_DRIFT}"
  echo "- active_traces not monotonically growing: ${PASS_AT}"
  echo "- fds_delta < 50: ${PASS_FDS} (skip when daemon does not expose process_open_fds)"
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
