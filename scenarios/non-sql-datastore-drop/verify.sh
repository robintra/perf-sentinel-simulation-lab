#!/usr/bin/env bash
# non-sql-datastore-drop: validate the 0.9.2 ingest drop of non-SQL datastore
# spans, coherently across the three ingestion paths.
#
#   Batch  : Jaeger + Zipkin fixtures fed to the local `analyze` binary
#            (these formats carry db.system in their tags).
#   Daemon : OTLP/protobuf POST to /v1/traces (the 3rd path + the
#            elasticsearch+url.full edge, checked first on OTLP per the task).
#
# Self-contained: needs only the local release binary. The OTLP leg launches a
# throwaway `perf-sentinel watch` daemon on a loopback port (fresh state, no
# cluster, no port-forward), exercising the exact ingest/otlp.rs path.
set -euo pipefail

SCENARIO="non-sql-datastore-drop"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIX="${SCRIPT_DIR}/fixtures"
mkdir -p "${TMP_DIR}"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
DAEMON_HTTP_PORT="${DAEMON_HTTP_PORT:-14392}"
DAEMON_GRPC_PORT="${DAEMON_GRPC_PORT:-14393}"
DAEMON_URL="http://127.0.0.1:${DAEMON_HTTP_PORT}"
SERVICE="shop-mixed"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

DAEMON_PID=""
cleanup() { [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true; }
trap cleanup EXIT

[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release -p perf-sentinel first)"

start_local_daemon() {
  # Kill any daemon orphaned on our port by a hard-interrupted prior run, so we
  # never bind-fail silently and then assert against a stale daemon's cumulative
  # metrics/findings (a false PASS). Matches the sibling 0.9.2 scenarios.
  pkill -f "perf-sentinel watch.*${DAEMON_HTTP_PORT}" 2>/dev/null || true
  sleep 1
  cat > "${TMP_DIR}/daemon.toml" <<EOF
[daemon]
listen_address = "127.0.0.1"
listen_port_http = ${DAEMON_HTTP_PORT}
listen_port_grpc = ${DAEMON_GRPC_PORT}
trace_ttl_ms = 2000
api_enabled = true
environment = "staging"

[detection]
n_plus_one_min_occurrences = 5
sanitizer_aware_classification = "strict"
EOF
  "${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/daemon.toml" > "${TMP_DIR}/daemon.log" 2>&1 &
  DAEMON_PID=$!
  for _ in $(seq 1 40); do
    curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}

metric_val() {  # $1 = full metric line key (with labels)
  awk -v m="$1" 'index($0,m)==1 {print int($2); found=1} END {if(!found) print 0}' "${TMP_DIR}/metrics.txt" | head -1
}

# Assert a findings JSON array (bare or {finding:...} wrapped) carries the
# PostgreSQL n_plus_one_sql for SERVICE and nothing on the dropped datastores.
assert_only_postgres() {
  python3 -c "
import json, sys
items = json.load(sys.stdin)
items = items if isinstance(items, list) else items.get('findings', [])
def u(it): return it.get('finding', it) if isinstance(it, dict) else {}
ours = [u(it) for it in items if u(it).get('service') == '${SERVICE}']
n1 = [f for f in ours if f.get('type') == 'n_plus_one_sql']
assert len(n1) >= 1, 'expected >=1 n_plus_one_sql for ${SERVICE}, got types=%s' % [f.get('type') for f in ours]
tpl = n1[0].get('pattern', {}).get('template', '')
assert 'orders' in tpl and '?' in tpl, 'unexpected pg template: %r' % tpl
blob = json.dumps(ours).lower()
for bad in ('redis', 'elasticsearch', 'user:', '_search', ':9200'):
    assert bad not in blob, 'dropped-datastore leak in findings: %r' % bad
assert all(f.get('type') == 'n_plus_one_sql' for f in ours), \
    'unexpected non-SQL finding: %s' % [f.get('type') for f in ours]
print(tpl)
"
}

# =============================================================================
# Part A: batch Jaeger + Zipkin (local binary)
# =============================================================================
for fmt in jaeger zipkin; do
  step "Batch ${fmt}: redis/elasticsearch dropped, only PostgreSQL N+1 survives"
  "${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${FIX}/mixed-${fmt}.json" --format json \
    > "${TMP_DIR}/${fmt}.json" 2>"${TMP_DIR}/${fmt}.err" \
    || die "analyze failed on ${fmt}: $(tail -2 "${TMP_DIR}/${fmt}.err")"
  EVENTS="$(python3 -c "import json;print(json.load(open('${TMP_DIR}/${fmt}.json'))['analysis']['events_processed'])")"
  [ "${EVENTS}" = "7" ] || die "${fmt}: events_processed=${EVENTS}, expected 7 (root + 6 pg; 6 redis + 1 es dropped)"
  TPL="$(cat "${TMP_DIR}/${fmt}.json" | assert_only_postgres)" || die "${fmt}: ${TPL:-assertion failed}"
  eval "BATCH_TPL_${fmt}=\"\${TPL}\""
  ok "${fmt}: 7 events kept, only n_plus_one_sql [${TPL}], no redis/es leak"
done

# =============================================================================
# Part B: OTLP daemon leg (throwaway local daemon)
# =============================================================================
step "OTLP daemon leg: drop + non_sql_datastore metric + elasticsearch not HTTP"
start_local_daemon || die "local daemon did not become ready on ${DAEMON_URL}: $(tail -3 "${TMP_DIR}/daemon.log")"
METRIC='perf_sentinel_otlp_spans_filtered_total{reason="non_sql_datastore"}'
HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST "${DAEMON_URL}/v1/traces" \
  -H 'Content-Type: application/x-protobuf' --data-binary @"${FIX}/mixed.pb")"
[ "${HTTP_CODE}" = "200" ] || die "OTLP POST returned ${HTTP_CODE}"
sleep 4
OTLP_TPL="$(curl -fsS "${DAEMON_URL}/api/findings" | assert_only_postgres)" \
  || die "OTLP findings assertion failed: ${OTLP_TPL:-}"
curl -fsS "${DAEMON_URL}/metrics" > "${TMP_DIR}/metrics.txt" 2>/dev/null || true
NON_SQL="$(metric_val "${METRIC}")"
NOT_IO="$(metric_val 'perf_sentinel_otlp_spans_filtered_total{reason="not_io"}')"
[ "${NON_SQL}" -ge 7 ] || die "non_sql_datastore=${NON_SQL}, expected >=7 (6 redis + 1 es)"
[ "${NOT_IO}" -eq 0 ] || die "es+url.full mis-bucketed: not_io=${NOT_IO}, expected 0 (es dropped on db.system)"
ok "OTLP: only n_plus_one_sql [${OTLP_TPL}], non_sql_datastore=${NON_SQL} (>=7), not_io=0 (es not HTTP/not_io)"

# =============================================================================
verdict="PASS"
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "| path | result |"
  echo "|---|---|"
  echo "| batch Jaeger | only n_plus_one_sql \`${BATCH_TPL_jaeger}\`, redis/es dropped (7/14 events kept) |"
  echo "| batch Zipkin | only n_plus_one_sql \`${BATCH_TPL_zipkin}\`, redis/es dropped (7/14 events kept) |"
  echo "| OTLP daemon | only n_plus_one_sql; non_sql_datastore=${NON_SQL}, not_io=0 (es+url.full dropped, not HTTP) |"
  echo ""
  echo "Verdict: **${verdict}**"
} > "${REPORT}"
color_green "PASS — report at ${REPORT}"
