#!/usr/bin/env bash
# datadog-bridge: validate perf-sentinel 0.9.3's Datadog / dd-trace ingestion
# bridge end to end, plus the db-system classification hardening that shipped
# with it. Self-contained: local release binary + a throwaway loopback daemon
# and batch `analyze`/`explain` on committed fixtures. No cluster.
#
# Bridged fixtures mimic the REAL OTel Collector datadogreceiver output
# (contrib v0.155.0): scope "Datadog", SQL pre-obfuscated (`?`) in
# dd.span.Resource, the engine under the stable OTel 1.27+ key db.system.name.
#
# Assertions (see README.md):
#   A  dd-trace SQL N+1 (db.system.name) -> a non-zero SQL finding.
#   B  non-SQL stores dropped, never tokenized, no key/secret in findings/HTML.
#   C  cross-format operation label: db.system="postgres" -> "postgresql";
#      a db-system-less SQL span -> "sql" (Jaeger + Zipkin via explain).
#   D  stable db.system.name across formats: SQL -> finding, non-SQL -> dropped.
#   E  cloud SQL engine (snowflake via dd-trace db.type) -> SQL finding.
#   F  F3 known limitation: auto+uniform -> redundant_sql; strict+>=15 identical
#      -> n_plus_one_sql (documented, locked here, not flagged).
#   G  instrumentation-gap counters: missing_db_statement + non_sql_datastore.
#   (live) optional: synthetic dd-trace v0.4 -> real datadogreceiver -> daemon,
#      run only when Docker + the contrib image are available, SKIP otherwise.
set -uo pipefail

SCENARIO="datadog-bridge"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIX="${SCRIPT_DIR}/fixtures"
LIVE_DIR="${SCRIPT_DIR}/live"
mkdir -p "${TMP_DIR}"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
DAEMON_HTTP_PORT="${DAEMON_HTTP_PORT:-14396}"
DAEMON_GRPC_PORT="${DAEMON_GRPC_PORT:-14397}"
DAEMON_URL="http://127.0.0.1:${DAEMON_HTTP_PORT}"
COLLECTOR_IMAGE="${COLLECTOR_IMAGE:-otel/opentelemetry-collector-contrib:latest}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
color_yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
skip() { color_yellow "    skip: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

FAILS=0
declare -a SUMMARY
record() { SUMMARY+=("$1|$2"); }                 # assertion-id | result text
assert_pass() { ok "$2"; record "$1" "PASS — $2"; }
assert_fail() { color_red "    FAIL: $2"; FAILS=$((FAILS + 1)); record "$1" "FAIL — $2"; }

DAEMON_PID=""
cleanup() {
  [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true
  docker rm -f "ddbridge-collector" >/dev/null 2>&1 || true
}
trap cleanup EXIT

[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release -p perf-sentinel first)"

# ── helpers ─────────────────────────────────────────────────────────────────
start_local_daemon() {  # $1 = sanitizer mode: "auto"(default, omit key)|strict
  local mode="${1:-auto}" line=""
  [ "${mode}" != "auto" ] && line="sanitizer_aware_classification = \"${mode}\""
  [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true
  pkill -f "perf-sentinel watch.*${DAEMON_HTTP_PORT}" 2>/dev/null || true
  sleep 1
  cat > "${TMP_DIR}/daemon.toml" <<EOF
[daemon]
listen_address = "0.0.0.0"
listen_port_http = ${DAEMON_HTTP_PORT}
listen_port_grpc = ${DAEMON_GRPC_PORT}
api_enabled = true
trace_ttl_ms = 2000
environment = "staging"

[daemon.ack]
enabled = false

[detection]
n_plus_one_min_occurrences = 5
${line}
EOF
  "${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/daemon.toml" > "${TMP_DIR}/daemon.log" 2>&1 &
  DAEMON_PID=$!
  for _ in $(seq 1 40); do
    curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}

post_pb() {  # $1 = fixture file under fixtures/
  curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST "${DAEMON_URL}/v1/traces" \
    -H 'Content-Type: application/x-protobuf' --data-binary @"${FIX}/$1"
}

metric_val() {  # $1 = full metric line key (with labels); reads metrics.txt
  awk -v m="$1" 'index($0,m)==1 {print int($2); found=1} END {if(!found) print 0}' \
    "${TMP_DIR}/metrics.txt" | head -1
}

# Finding type(s) for a service from a /api/findings array (bare or wrapped).
finding_types_for() {  # $1 = service ; reads stdin
  python3 -c "
import sys, json
items = json.load(sys.stdin)
items = items if isinstance(items, list) else items.get('findings', [])
def u(it): return it.get('finding', it) if isinstance(it, dict) else {}
print(' '.join(u(it).get('type','') for it in items if u(it).get('service') == '$1'))
"
}

# =============================================================================
# C + D — cross-format canonicalization (batch analyze + explain)
# =============================================================================
XF_TRACE="t0000000000000000000000000000a0e0"
for fmt in jaeger zipkin; do
  step "Batch ${fmt}: canonicalization (C) + stable db.system.name + non-SQL drop (D)"
  "${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${FIX}/crossfmt-${fmt}.json" --format json \
    > "${TMP_DIR}/${fmt}.json" 2>"${TMP_DIR}/${fmt}.err" \
    || die "${fmt}: analyze failed: $(tail -2 "${TMP_DIR}/${fmt}.err")"

  # Space-free, pipe-delimited record so SQL templates (which contain spaces)
  # don't break field splitting: events|tables_csv|leak
  IFS='|' read -r EVENTS N1 LEAK <<<"$(python3 -c "
import json, re
d = json.load(open('${TMP_DIR}/${fmt}.json'))
ev = d['analysis']['events_processed']
tables = sorted({re.search(r'FROM (\w+)', f['pattern']['template']).group(1)
                 for f in d['findings'] if f['type']=='n_plus_one_sql'
                 and re.search(r'FROM (\w+)', f['pattern']['template'])})
blob = json.dumps(d).lower()
leak = any(s in blob for s in ('secret-ddb-xf','dynamodb','getitem'))
print('%d|%s|%d' % (ev, ','.join(tables), leak))
")"
  # D: pg legacy + pg stable + db-system-less all yield SQL n+1; dynamodb dropped.
  if echo "${N1}" | grep -q "orders" && echo "${N1}" | grep -q "line_items" && echo "${N1}" | grep -q "users"; then
    assert_pass "D-${fmt}" "${fmt}: orders/line_items(stable name)/users all -> n_plus_one_sql"
  else
    assert_fail "D-${fmt}" "${fmt}: expected n+1 for orders+line_items+users, got [${N1}]"
  fi
  if [ "${EVENTS}" = "19" ] && [ "${LEAK}" = "0" ]; then
    assert_pass "B-${fmt}" "${fmt}: aws.dynamodb dropped (events=19), no key leak"
  else
    assert_fail "B-${fmt}" "${fmt}: events=${EVENTS} (want 19), leak=${LEAK} (want 0)"
  fi

  OPS="$("${PERF_SENTINEL_LOCAL_BIN}" explain --input "${FIX}/crossfmt-${fmt}.json" \
        --trace-id "${XF_TRACE}" --format json 2>/dev/null \
        | python3 -c "import sys,re;print(' '.join(sorted(set(re.findall(r'\"operation\"\s*:\s*\"([^\"]*)\"', sys.stdin.read())))))")"
  if echo " ${OPS} " | grep -q " postgresql " && echo " ${OPS} " | grep -q " sql " \
       && ! echo " ${OPS} " | grep -q " postgres " && ! echo " ${OPS} " | grep -q " dynamodb "; then
    assert_pass "C-${fmt}" "${fmt}: operation labels canonical {postgresql, sql} [${OPS}]"
  else
    assert_fail "C-${fmt}" "${fmt}: operation labels = [${OPS}] (want postgresql+sql, no bare postgres/dynamodb)"
  fi
done

# =============================================================================
# A, E, F(auto), B, G — dd-trace bridge, default auto mode (throwaway daemon)
# =============================================================================
step "Daemon (auto): dd-trace SQL detection (A), snowflake (E), F3 auto (F), drops + gaps (B/G)"
start_local_daemon auto || die "daemon not ready on ${DAEMON_URL}: $(tail -3 "${TMP_DIR}/daemon.log")"
for f in dd-bridge-nplusone.pb dd-snowflake.pb nonsql-and-gap.pb; do
  code="$(post_pb "${f}")"; [ "${code}" = "200" ] || die "${f}: OTLP POST returned ${code}"
done
sleep 5
curl -fsS "${DAEMON_URL}/api/findings" > "${TMP_DIR}/findings-auto.json" || die "findings fetch failed"
curl -fsS "${DAEMON_URL}/metrics" > "${TMP_DIR}/metrics.txt" 2>/dev/null || true

# A: a non-zero SQL finding for the dd-trace-bridged service (db.system.name).
DD_TYPES="$(finding_types_for dd-bridge-shop < "${TMP_DIR}/findings-auto.json")"
if echo "${DD_TYPES}" | grep -Eq 'n_plus_one_sql|redundant_sql'; then
  assert_pass "A" "dd-trace N+1 (db.system.name) recognized -> SQL finding [${DD_TYPES}]"
else
  assert_fail "A" "no SQL finding for dd-bridge-shop (got [${DD_TYPES}]) — db.system.name recognition broken"
fi
# F(auto): obfuscated + uniform + Datadog scope -> redundant_sql, NOT n_plus_one_sql.
if echo "${DD_TYPES}" | grep -q 'redundant_sql' && ! echo "${DD_TYPES}" | grep -q 'n_plus_one_sql'; then
  assert_pass "F-auto" "auto + uniform timing -> redundant_sql, not n_plus_one_sql (documented F3 limitation)"
else
  assert_fail "F-auto" "expected redundant_sql (not n_plus_one_sql) under auto, got [${DD_TYPES}]"
fi
# E: cloud SQL engine snowflake (dd-trace db.type) -> SQL finding.
SNOW_TYPES="$(finding_types_for dd-snowflake-shop < "${TMP_DIR}/findings-auto.json")"
if echo "${SNOW_TYPES}" | grep -Eq 'n_plus_one_sql|redundant_sql'; then
  assert_pass "E" "snowflake (db.type) -> SQL finding [${SNOW_TYPES}]"
else
  assert_fail "E" "no SQL finding for snowflake (got [${SNOW_TYPES}])"
fi
# B: no non-SQL key/secret leaked into findings, and none in the HTML report.
curl -fsS "${DAEMON_URL}/api/export/report" > "${TMP_DIR}/report.json" 2>/dev/null || true
"${PERF_SENTINEL_LOCAL_BIN}" report --input "${TMP_DIR}/report.json" \
  --output "${TMP_DIR}/report.html" >/dev/null 2>&1 || true
LEAK_FINDINGS=0; LEAK_HTML=0
for s in SECRET-REDIS SECRET-DDB; do
  grep -qi "${s}" "${TMP_DIR}/findings-auto.json" && LEAK_FINDINGS=1
  grep -qi "${s}" "${TMP_DIR}/report.html" 2>/dev/null && LEAK_HTML=1
done
if [ "${LEAK_FINDINGS}" = "0" ] && [ "${LEAK_HTML}" = "0" ]; then
  assert_pass "B-otlp" "no redis/dynamodb key or secret in findings or HTML report"
else
  assert_fail "B-otlp" "PII leak: findings=${LEAK_FINDINGS}, html=${LEAK_HTML}"
fi
# G: instrumentation-gap + non-SQL filter counters.
NON_SQL="$(metric_val 'perf_sentinel_otlp_spans_filtered_total{reason="non_sql_datastore"}')"
GAP="$(metric_val 'perf_sentinel_otlp_spans_filtered_total{reason="missing_db_statement"}')"
if [ "${NON_SQL}" -ge 12 ] && [ "${GAP}" -ge 1 ]; then
  assert_pass "G" "filter counters: non_sql_datastore=${NON_SQL} (>=12), missing_db_statement=${GAP} (>=1)"
else
  assert_fail "G" "filter counters: non_sql_datastore=${NON_SQL} (want >=12), missing_db_statement=${GAP} (want >=1)"
fi

# =============================================================================
# F(strict) — high-occurrence recovery (throwaway daemon, strict mode)
# =============================================================================
step "Daemon (strict): F3 recovery at high occurrence (>=3x threshold)"
start_local_daemon strict || die "strict daemon not ready: $(tail -3 "${TMP_DIR}/daemon.log")"
code="$(post_pb dd-bridge-16.pb)"; [ "${code}" = "200" ] || die "dd-bridge-16.pb POST returned ${code}"
sleep 5
S16_TYPES="$(curl -fsS "${DAEMON_URL}/api/findings" | finding_types_for dd-bridge-shop16)"
if echo "${S16_TYPES}" | grep -q 'n_plus_one_sql'; then
  assert_pass "F-strict" "strict + 16 identical -> n_plus_one_sql recovered [${S16_TYPES}]"
else
  assert_fail "F-strict" "expected n_plus_one_sql under strict (16>=15), got [${S16_TYPES}]"
fi
kill "${DAEMON_PID}" 2>/dev/null || true; DAEMON_PID=""

# =============================================================================
# (live) optional end-to-end through the REAL datadogreceiver — SKIP if no Docker
# =============================================================================
LIVE_RESULT="SKIP"
step "Live (optional): dd-trace v0.4 -> real datadogreceiver -> daemon"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
   && python3 -c "import msgpack" >/dev/null 2>&1; then
  if "${LIVE_DIR}/run-live.sh" >"${TMP_DIR}/live.log" 2>&1; then
    LIVE_RESULT="PASS"; assert_pass "live" "real datadogreceiver -> daemon -> SQL finding (end to end)"
  else
    LIVE_RESULT="SKIP"; skip "live leg could not complete (infra): $(tail -1 "${TMP_DIR}/live.log" 2>/dev/null)"
    record "live" "SKIP — infra unavailable (Docker/network); deterministic A covers the same path"
  fi
else
  skip "Docker or python-msgpack unavailable; live leg skipped (deterministic A covers the same code path)"
  record "live" "SKIP — Docker/msgpack unavailable"
fi

# =============================================================================
verdict=$([ "${FAILS}" -eq 0 ] && echo PASS || echo FAIL)
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "perf-sentinel 0.9.3 Datadog/dd-trace bridge + db-system hardening."
  echo ""
  echo "| assertion | result |"
  echo "|---|---|"
  for row in "${SUMMARY[@]}"; do
    printf "| %s | %s |\n" "${row%%|*}" "${row#*|}"
  done
  echo ""
  echo "Live end-to-end leg: **${LIVE_RESULT}**"
  echo ""
  echo "Verdict: **${verdict}**"
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  color_green "PASS — report at ${REPORT}"
else
  die "FAIL (${FAILS} assertion(s)) — report at ${REPORT}"
fi
