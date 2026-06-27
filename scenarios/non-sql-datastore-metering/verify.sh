#!/usr/bin/env bash
# non-sql-datastore-metering: validate the 0.9.2 metering + zero-retention
# warning behaviour around the non-SQL datastore drop.
#
#   1. Redis-only fleet (1250 redis spans, all dropped):
#        perf_sentinel_otlp_spans_filtered_total{reason="non_sql_datastore"} >= 1250
#        AND the /api/export/report zero-retention warning is ABSENT
#        (0.9.2 excludes non_sql_datastore from the instrumentation-gap sum).
#   2. Internal-only fleet (1250 not_io spans) — the negative control:
#        the zero-retention warning is PRESENT (not_io still counts toward the
#        gap, so a genuine instrumentation gap is still surfaced).
#
# The warning lives in the Report (`/api/export/report`), which short-circuits
# to a cold-start envelope until the daemon has analyzed >=1 trace. A 100%-
# filtered fleet would never escape cold-start, so each case first seeds ONE
# analyzable trace over the NDJSON socket (a non-OTLP path: it bumps
# events/traces analyzed WITHOUT touching otlp_spans_received_total), then
# floods OTLP. received then equals the flood alone, so gap >= received holds
# exactly when the flood is not_io and never when it is non_sql_datastore.
#
# Self-contained: needs only the local release binary. Each case runs a fresh
# throwaway daemon (received/filtered are cumulative whole-daemon counters).
set -euo pipefail

SCENARIO="non-sql-datastore-metering"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIX="${SCRIPT_DIR}/fixtures"
mkdir -p "${TMP_DIR}"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
DAEMON_HTTP_PORT="${DAEMON_HTTP_PORT:-14396}"
DAEMON_GRPC_PORT="${DAEMON_GRPC_PORT:-14397}"
DAEMON_URL="http://127.0.0.1:${DAEMON_HTTP_PORT}"
# AF_UNIX path must stay short (~104 char limit), so /tmp not the scratch dir.
# Per-pid suffix avoids colliding with a leftover socket from a crashed run
# (possibly owned by another user, which `rm -f` could not clear).
SOCK="${SOCK:-/tmp/ps-nsm-$$.sock}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

DAEMON_PID=""
cleanup() { [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true; rm -f "${SOCK}" 2>/dev/null || true; }
trap cleanup EXIT

[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release -p perf-sentinel first)"

start_fresh_daemon() {
  [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true
  pkill -f "perf-sentinel watch.*${DAEMON_HTTP_PORT}" 2>/dev/null || true
  rm -f "${SOCK}"
  sleep 1
  cat > "${TMP_DIR}/daemon.toml" <<EOF
[daemon]
listen_address = "127.0.0.1"
listen_port_http = ${DAEMON_HTTP_PORT}
listen_port_grpc = ${DAEMON_GRPC_PORT}
json_socket = "${SOCK}"
api_enabled = true
trace_ttl_ms = 1500

[daemon.ack]
enabled = false

[detection]
n_plus_one_min_occurrences = 5
EOF
  "${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/daemon.toml" > "${TMP_DIR}/daemon.log" 2>&1 &
  DAEMON_PID=$!
  for _ in $(seq 1 40); do
    curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 && break
    sleep 0.5
  done
  for _ in $(seq 1 20); do [ -S "${SOCK}" ] && return 0; sleep 0.5; done
  return 1
}

seed_analyzable_trace() {  # one N+1 over the NDJSON socket -> escape cold-start
  python3 -c "
import socket, json
ev=[{'timestamp':'2025-06-07T12:00:00.%03dZ'%(i*4),'trace_id':'tseed','span_id':'ss%d'%i,
     'parent_span_id':'ss0','service':'seed-svc','cloud_region':'eu-west-3','type':'sql',
     'operation':'SELECT','target':'SELECT * FROM seed WHERE id = %d'%i,'duration_us':2000,
     'source':{'endpoint':'/seed','method':'h'}} for i in range(1,7)]
s=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect('${SOCK}')
s.sendall((json.dumps(ev)+'\n').encode()); s.close()
"
}

metric_val() {
  awk -v m="$1" 'index($0,m)==1 {print int($2); found=1} END {if(!found) print 0}' "${TMP_DIR}/metrics.txt" | head -1
}

# Returns "yes"/"no" on stdout: is the zero-retention warning in the Report?
zero_retention_warning() {
  curl -fsS "${DAEMON_URL}/api/export/report" | python3 -c "
import sys, json
r = json.load(sys.stdin)
msgs = [w.get('message','') for w in r.get('warning_details', [])]
print('yes' if any('non-analyzable' in m for m in msgs) else 'no')
"
}

run_case() {  # $1 = fixture, $2 = expected warning yes/no
  local fixture="$1" expect="$2"
  start_fresh_daemon || die "daemon/socket not ready (${fixture}): $(tail -3 "${TMP_DIR}/daemon.log")"
  seed_analyzable_trace
  sleep 2
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -X POST "${DAEMON_URL}/v1/traces" \
    -H 'Content-Type: application/x-protobuf' --data-binary @"${FIX}/${fixture}")"
  [ "${code}" = "200" ] || die "${fixture}: OTLP POST returned ${code}"
  sleep 2
  curl -fsS "${DAEMON_URL}/metrics" > "${TMP_DIR}/metrics.txt" 2>/dev/null || true
  CASE_NON_SQL="$(metric_val 'perf_sentinel_otlp_spans_filtered_total{reason="non_sql_datastore"}')"
  CASE_NOT_IO="$(metric_val 'perf_sentinel_otlp_spans_filtered_total{reason="not_io"}')"
  CASE_WARN="$(zero_retention_warning)"
  [ "${CASE_WARN}" = "${expect}" ] \
    || die "${fixture}: zero-retention warning=${CASE_WARN}, expected ${expect} (non_sql=${CASE_NON_SQL} not_io=${CASE_NOT_IO})"
}

# --- 1. redis-only: counter rises, NO warning -------------------------------
step "Redis-only fleet: non_sql_datastore counter rises, zero-retention warning absent"
run_case redis-only.pb no
[ "${CASE_NON_SQL}" -ge 1250 ] || die "non_sql_datastore=${CASE_NON_SQL}, expected >=1250"
[ "${CASE_NOT_IO}" -eq 0 ] || die "redis fleet leaked into not_io=${CASE_NOT_IO}"
REDIS_NON_SQL="${CASE_NON_SQL}"
ok "redis-only: non_sql_datastore=${REDIS_NON_SQL} (>=1250), not_io=0, warning absent (excluded)"

# --- 2. internal-only: warning fires (negative control) ---------------------
step "Internal-only fleet: not_io still counts, zero-retention warning present"
run_case internal-only.pb yes
[ "${CASE_NOT_IO}" -ge 1250 ] || die "not_io=${CASE_NOT_IO}, expected >=1250"
INTERNAL_NOT_IO="${CASE_NOT_IO}"
ok "internal-only: not_io=${INTERNAL_NOT_IO} (>=1250), warning present (not_io counts)"

# =============================================================================
verdict="PASS"
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "| case | non_sql_datastore | not_io | zero-retention warning |"
  echo "|---|---|---|---|"
  echo "| redis-only (1250 spans) | ${REDIS_NON_SQL} | 0 | absent (excluded by 0.9.2) |"
  echo "| internal-only (1250 spans) | 0 | ${INTERNAL_NOT_IO} | present (not_io still counts) |"
  echo ""
  echo "Verdict: **${verdict}**"
} > "${REPORT}"
color_green "PASS — report at ${REPORT}"
