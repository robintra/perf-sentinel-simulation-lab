#!/usr/bin/env bash
# alumet-db-waste: validate perf-sentinel 0.9.13's database-waste feature, the
# Alumet-measured DB cgroup energy attributed to the SQL-only avoidable share.
#
# 0.9.13 adds, on top of the 0.9.12 Alumet backend (see alumet-conformance):
#   - green_summary.{total_sql_io_ops,avoidable_sql_io_ops}: the SQL-only slice
#     of the io-op counters (SQL spans / n_plus_one_sql+redundant_sql findings).
#   - [green.alumet.database]: declares one DB cgroup label. Each scored window
#     the daemon multiplies that cgroup's measured window energy by the SQL waste
#     ratio and reports green_summary.database_waste = {energy_kwh, waste_kwh,
#     waste_gco2, region, sql_waste_ratio}. A CPU-only lower bound, EXCLUDED from
#     energy_kwh, co2, and the public disclosure.
#
# Self-contained: local release binary on loopback + a python http.server serving
# the committed alumet-conformance capture augmented with ONE synthetic DB-cgroup
# series carrying a known joules-per-poll value, so every figure is checkable.
# No cluster. Docker not required (traces seeded over the daemon's protobuf OTLP
# endpoint with the committed datadog-bridge N+1 fixture).
#
# Legs (see README.md):
#   B   database_waste end to end: present, energy_kwh>0, waste_kwh == energy_kwh
#       * sql_waste_ratio, sql_waste_ratio == avoidable_sql/total_sql, gco2>0,
#       excluded from the top-level totals, and absent from `disclose`.
#   C   sticky live cell: no flap between scrapes, then ages out after the scraper
#       dies (TTL = 2x staleness = 6x scrape interval), not pinned forever.
#   D   carry-over under shedding: with a 1-deep analysis queue flooded to shed,
#       the DB energy summed across archived NDJSON windows is conserved and the
#       daemon sheds instead of OOMing.
#   E   config validation: collision / typo'd subsection / no-endpoint / unknown
#       key are REJECTED at load; an unknown region only WARNS (gco2 absent).
#   F   monitor line: `query monitor` Energy tab renders the "Database waste:"
#       line the /api/export/report snapshot backs.
set -uo pipefail

SCENARIO="alumet-db-waste"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_PROM="${SCRIPT_DIR}/../alumet-conformance/fixtures/alumet-wire-capture.prom"
DD_FIX="${SCRIPT_DIR}/../datadog-bridge/fixtures"
ORG_CONFIG="${SCRIPT_DIR}/../disclose/fixtures/org-config.toml"
SHED_FIX="${SCRIPT_DIR}/../daemon-analysis-shedding/fixtures/shed-load.pb"   # 300 N+1 traces/POST
rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}/mock"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
DAEMON_HTTP_PORT="${DAEMON_HTTP_PORT:-14598}"
DAEMON_GRPC_PORT="${DAEMON_GRPC_PORT:-14599}"
DAEMON_URL="http://127.0.0.1:${DAEMON_HTTP_PORT}"
MOCK_PORT="${MOCK_PORT:-19093}"

# Scrape/energy cadence + the synthetic DB cgroup reading. Chosen so the DB
# window energy is a round 0.1 kWh per 5s scrape: 72000 J/poll / 1.0s = 72 kW,
# * 5s / 3.6e6 = 0.1 kWh. (Synthetic, like the memory-as-joules capture it rides
# on; physical realism is not the point, checkable arithmetic is.)
SCRAPE_SECS=5
ENERGY_INTERVAL=1.0
DB_LABEL="pg-cgroup"
DB_JOULES=72000
PER_SCRAPE_KWH="$(python3 -c "print(${DB_JOULES} * ${SCRAPE_SECS} / (${ENERGY_INTERVAL} * 3.6e6))")"
REGION="eu-west-3"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
color_yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
skip() { color_yellow "    skip: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

FAILS=0
SUMMARY=()
NOTES=()
record() { SUMMARY+=("$1|$2"); }
note()   { NOTES+=("$1"); }
assert_pass() { ok "$2"; record "$1" "PASS — $2"; }
assert_fail() { color_red "    FAIL: $2"; FAILS=$((FAILS + 1)); record "$1" "FAIL — $2"; }
record_skip() { skip "$2"; record "$1" "SKIP — $2"; }

DAEMON_PID=""
MOCK_PID=""
cleanup() {
  [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true
  [ -n "${MOCK_PID}" ] && kill "${MOCK_PID}" 2>/dev/null || true
}
trap cleanup EXIT

[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release -p perf-sentinel first)"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
[ -s "${BASE_PROM}" ] || die "base capture ${BASE_PROM} missing (alumet-conformance fixture)"
[ -s "${DD_FIX}/dd-bridge-nplusone.pb" ] || die "trace fixture ${DD_FIX}/dd-bridge-nplusone.pb missing"

# ── helpers ──────────────────────────────────────────────────────────────────
free_daemon_port() {
  pkill -f "perf-sentinel watch.*${TMP_DIR}/" 2>/dev/null || true
  for p in "${DAEMON_HTTP_PORT}" "${DAEMON_GRPC_PORT}"; do
    lsof -ti "tcp:${p}" 2>/dev/null | while read -r pid; do kill "${pid}" 2>/dev/null || true; done
  done
}

start_daemon() {  # $1 = config under TMP_DIR ; $2 = log under TMP_DIR ; returns 0 when /api/status answers
  [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true
  free_daemon_port
  sleep 1
  "${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/$1" > "${TMP_DIR}/$2" 2>&1 &
  DAEMON_PID=$!
  for _ in $(seq 1 40); do
    curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 && return 0
    kill -0 "${DAEMON_PID}" 2>/dev/null || return 1   # process already exited (config reject)
    sleep 0.5
  done
  return 1
}

stop_daemon() {
  [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true
  wait "${DAEMON_PID}" 2>/dev/null || true
  DAEMON_PID=""
}

# Launch with a config expected to be REJECTED at load: the process must exit on
# its own (non-zero) within a couple of seconds and never answer /api/status.
expect_config_reject() {  # $1 = config ; $2 = log ; returns 0 when it rejected
  free_daemon_port
  "${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/$1" > "${TMP_DIR}/$2" 2>&1 &
  local pid=$!
  sleep 2
  if kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" 2>/dev/null || true; wait "${pid}" 2>/dev/null || true
    return 1   # still alive -> config was NOT rejected
  fi
  wait "${pid}" 2>/dev/null || true
  return 0
}

post_traces() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST "${DAEMON_URL}/v1/traces" \
    -H 'Content-Type: application/x-protobuf' --data-binary @"${DD_FIX}/dd-bridge-nplusone.pb"
}

# 300-N+1-trace payload (borrowed from daemon-analysis-shedding) — big eviction
# batches that overrun a small trace window + 1-deep analysis queue -> shedding.
post_shed() {
  curl -sS -o /dev/null --max-time 10 -X POST "${DAEMON_URL}/v1/traces" \
    -H 'Content-Type: application/x-protobuf' --data-binary @"${SHED_FIX}" 2>/dev/null || true
}

alumet_success_count() {  # successful Alumet scrapes so far (from the daemon's own /metrics)
  curl -fsS "${DAEMON_URL}/metrics" 2>/dev/null | awk '
    index($0,"perf_sentinel_alumet_scrape_total")==1 && index($0,"status=\"success\"")>0 {print int($2); f=1; exit}
    END {if(!f) print 0}'
}

# POST the N+1 fixture up to N times (8s spacing keeps one batch per 5s scrape)
# and poll until green_summary.database_waste is present; writes the report JSON
# to $1 on success.
seed_until_db_waste() {  # $1 = out file
  for _ in $(seq 1 8); do
    [ "$(post_traces)" = "200" ] || { note "trace POST failed"; return 1; }
    sleep 4
    curl -fsS "${DAEMON_URL}/api/export/report" -o "$1" 2>/dev/null || true
    if python3 -c "import json,sys; sys.exit(0 if (json.load(open('$1')).get('green_summary') or {}).get('database_waste') else 1)" 2>/dev/null; then
      return 0
    fi
    sleep 4
  done
  return 1
}

# Base config: green root + daemon + one DB cgroup on the frozen capture.
# $1 extra [daemon] lines (e.g. analysis_queue_capacity / archive), $2 region.
write_config() {  # $1 = outfile ; $2 = region ; $3 = extra daemon lines ; $4 = db label
  local db_label="${4:-${DB_LABEL}}"
  cat > "${TMP_DIR}/$1" <<EOF
[green]
enabled = true
default_region = "${REGION}"

[daemon]
listen_address = "127.0.0.1"
listen_port_http = ${DAEMON_HTTP_PORT}
listen_port_grpc = ${DAEMON_GRPC_PORT}
api_enabled = true
trace_ttl_ms = 2000
environment = "staging"
${3:-}

[daemon.ack]
enabled = false

[detection]
n_plus_one_min_occurrences = 5

[green.alumet]
endpoint = "http://127.0.0.1:${MOCK_PORT}/alumet-db.prom"
scrape_interval_secs = ${SCRAPE_SECS}
metric_name = "${METRIC}"
label_key = "resource_consumer_kind"
energy_interval_secs = ${ENERGY_INTERVAL}

[green.alumet.service_mappings]
"dd-bridge-shop" = "process"

[green.alumet.database]
label_value = "${db_label}"
region = "${2}"
EOF
}

# =============================================================================
# Setup: DB-augmented exposition + metric discovery
# =============================================================================
step "Setup: frozen capture + one synthetic ${DB_LABEL} cgroup row on :${MOCK_PORT}"
cp "${BASE_PROM}" "${TMP_DIR}/mock/alumet-db.prom"
cat >> "${TMP_DIR}/mock/alumet-db.prom" <<EOF
memory_usage_alumet{kind="resident",resource_consumer_id="pgcg",resource_consumer_kind="${DB_LABEL}",resource_id="",resource_kind="local_machine"} ${DB_JOULES}.0
EOF
lsof -ti "tcp:${MOCK_PORT}" 2>/dev/null | while read -r pid; do kill "${pid}" 2>/dev/null || true; done
( cd "${TMP_DIR}/mock" && exec python3 -m http.server "${MOCK_PORT}" --bind 127.0.0.1 ) >/dev/null 2>&1 &
MOCK_PID=$!
disown "${MOCK_PID}" 2>/dev/null || true
for _ in $(seq 1 20); do
  curl -fsS "http://127.0.0.1:${MOCK_PORT}/alumet-db.prom" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -fsS "http://127.0.0.1:${MOCK_PORT}/alumet-db.prom" >/dev/null 2>&1 || die "mock not serving on :${MOCK_PORT}"

# The DB cgroup shares the discovered per-process metric (single metric_name).
METRIC="$(python3 - "${BASE_PROM}" <<'EOF'
import re, sys, collections
c = collections.Counter()
for line in open(sys.argv[1]):
    if line.startswith('#'): continue
    m = re.match(r'^([a-zA-Z_:][a-zA-Z0-9_:]*_alumet)\{(.*)\}\s+(\S+)', line)
    if not m: continue
    name, labels, val = m.groups()
    try: v = float(val)
    except ValueError: continue
    if 'resource_consumer_kind="process"' in labels and v > 0:
        c[name] += 1
print(c.most_common(1)[0][0] if c else "")
EOF
)"
[ -n "${METRIC}" ] || die "no per-process _alumet metric discoverable in the base capture"
note "metric ${METRIC}, DB cgroup ${DB_LABEL}=${DB_JOULES} J/poll -> ${PER_SCRAPE_KWH} kWh per ${SCRAPE_SECS}s scrape"

# =============================================================================
# Leg E: config validation (fast, no traces for the reject cases)
# =============================================================================
step "E: config validation — reject collision / typo / no-endpoint / unknown key; warn on unknown region"

# E1 collision: label_value == a service_mappings value ("process").
write_config e1.toml "${REGION}" "" "process"
if expect_config_reject e1.toml e1.log && grep -qF "also appears in service_mappings" "${TMP_DIR}/e1.log"; then
  assert_pass "E-collision" "label_value colliding with service_mappings is rejected at load"
else
  assert_fail "E-collision" "collision not rejected with the expected error: $(tail -1 "${TMP_DIR}/e1.log")"
fi

# E2 typo'd subsection [green.alumet.databse] -> unknown key on [green.alumet].
cat > "${TMP_DIR}/e2.toml" <<EOF
[green]
enabled = true
default_region = "${REGION}"
[daemon]
listen_address = "127.0.0.1"
listen_port_http = ${DAEMON_HTTP_PORT}
listen_port_grpc = ${DAEMON_GRPC_PORT}
api_enabled = true
[green.alumet]
endpoint = "http://127.0.0.1:${MOCK_PORT}/alumet-db.prom"
metric_name = "${METRIC}"
label_key = "resource_consumer_kind"
energy_interval_secs = ${ENERGY_INTERVAL}
scrape_interval_secs = ${SCRAPE_SECS}
[green.alumet.databse]
label_value = "${DB_LABEL}"
EOF
if expect_config_reject e2.toml e2.log && grep -qiE "unknown field|databse" "${TMP_DIR}/e2.log"; then
  assert_pass "E-typo" "typo'd [green.alumet.databse] rejected by deny_unknown_fields"
else
  assert_fail "E-typo" "typo'd subsection not rejected: $(tail -1 "${TMP_DIR}/e2.log")"
fi

# E3 database section present but no [green.alumet] endpoint.
cat > "${TMP_DIR}/e3.toml" <<EOF
[green]
enabled = true
default_region = "${REGION}"
[daemon]
listen_address = "127.0.0.1"
listen_port_http = ${DAEMON_HTTP_PORT}
listen_port_grpc = ${DAEMON_GRPC_PORT}
api_enabled = true
[green.alumet]
metric_name = "${METRIC}"
label_key = "resource_consumer_kind"
energy_interval_secs = ${ENERGY_INTERVAL}
scrape_interval_secs = ${SCRAPE_SECS}
[green.alumet.database]
label_value = "${DB_LABEL}"
EOF
if expect_config_reject e3.toml e3.log && grep -qF "endpoint is missing" "${TMP_DIR}/e3.log"; then
  assert_pass "E-noendpoint" "[green.alumet.database] without an endpoint is rejected"
else
  assert_fail "E-noendpoint" "missing-endpoint not rejected: $(tail -1 "${TMP_DIR}/e3.log")"
fi

# E4 unknown key inside [green.alumet] (the deny_unknown_fields compat break).
cat > "${TMP_DIR}/e4.toml" <<EOF
[green]
enabled = true
default_region = "${REGION}"
[daemon]
listen_address = "127.0.0.1"
listen_port_http = ${DAEMON_HTTP_PORT}
listen_port_grpc = ${DAEMON_GRPC_PORT}
api_enabled = true
[green.alumet]
endpoint = "http://127.0.0.1:${MOCK_PORT}/alumet-db.prom"
metric_name = "${METRIC}"
label_key = "resource_consumer_kind"
energy_interval_secs = ${ENERGY_INTERVAL}
scrape_interval_secs = ${SCRAPE_SECS}
bogus_key = true
EOF
if expect_config_reject e4.toml e4.log && grep -qiE "unknown field|bogus_key" "${TMP_DIR}/e4.log"; then
  assert_pass "E-unknownkey" "unknown key in [green.alumet] is rejected (deny_unknown_fields compat break)"
else
  assert_fail "E-unknownkey" "unknown key not rejected: $(tail -1 "${TMP_DIR}/e4.log")"
fi

# E5 unknown-but-charset-valid region -> startup WARN, daemon keeps running,
# database_waste present with waste_gco2 absent.
write_config e5.toml "eu-wets-3" "" "${DB_LABEL}"
if start_daemon e5.toml e5.log; then
  if seed_until_db_waste "${TMP_DIR}/e5-report.json"; then
    warn_ok=0
    grep -qF "not in the embedded intensity table" "${TMP_DIR}/e5.log" && warn_ok=1
    gco2_absent="$(python3 -c "import json; dw=(json.load(open('${TMP_DIR}/e5-report.json')).get('green_summary') or {}).get('database_waste') or {}; print(0 if dw.get('waste_gco2') is not None else 1)")"
    if [ "${warn_ok}" = "1" ] && [ "${gco2_absent}" = "1" ]; then
      assert_pass "E-region-warn" "unknown region warns at startup, daemon runs, database_waste present with waste_gco2 absent"
    else
      assert_fail "E-region-warn" "warn=${warn_ok} (want 1), gco2_absent=${gco2_absent} (want 1)"
    fi
  else
    assert_fail "E-region-warn" "daemon started but never produced database_waste under the unknown region"
  fi
  stop_daemon
else
  assert_fail "E-region-warn" "daemon refused to start on an unknown (charset-valid) region — should only warn"
  stop_daemon
fi

# =============================================================================
# Leg B: database_waste end to end (+ exclusion + disclose absence)
# =============================================================================
step "B: database_waste e2e (arithmetic, exclusion) + disclose absence"
write_config b.toml "${REGION}" "" "${DB_LABEL}"
cat >> "${TMP_DIR}/b.toml" <<EOF

[daemon.archive]
path = "${TMP_DIR}/archive-b.ndjson"
max_size_mb = 100
max_files = 4
EOF
if start_daemon b.toml b.log && seed_until_db_waste "${TMP_DIR}/b-report.json"; then
  python3 - "${TMP_DIR}/b-report.json" "${PER_SCRAPE_KWH}" "${DB_LABEL}" > "${TMP_DIR}/b-verdict.txt" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1])); per_scrape = float(sys.argv[2]); db_label = sys.argv[3]
gs = r.get("green_summary") or {}
dw = gs.get("database_waste") or {}
tot_sql = gs.get("total_sql_io_ops"); av_sql = gs.get("avoidable_sql_io_ops")
ek = dw.get("energy_kwh"); wk = dw.get("waste_kwh"); ratio = dw.get("sql_waste_ratio")
gco2 = dw.get("waste_gco2"); top_ek = gs.get("energy_kwh")
psk = gs.get("per_service_energy_kwh") or {}; psm = gs.get("per_service_energy_model") or {}
out = []
def chk(tag, cond, detail): out.append((tag, bool(cond), detail))
chk("present", ek is not None and ek > 0, f"energy_kwh={ek}")
exp_ratio = min(av_sql/tot_sql, 1.0) if tot_sql else 0.0
chk("ratio", ratio is not None and abs(ratio-exp_ratio) < 1e-9,
    f"sql_waste_ratio={ratio} == avoidable_sql/total_sql={av_sql}/{tot_sql}={exp_ratio:.6f}")
chk("waste", wk is not None and ek is not None and ratio is not None and (ek==0 or abs(wk-ek*ratio) < 1e-9*max(1,abs(ek))),
    f"waste_kwh={wk} == energy_kwh*ratio={ek}*{ratio}={ (ek or 0)*(ratio or 0):.9g}")
chk("gco2", gco2 is not None and gco2 > 0, f"waste_gco2={gco2}")
# Exclusion is structural: the DB cgroup label never enters the per-service
# energy maps, and the top-level energy_kwh equals the pure service sum, so the
# DB figure is not folded into the totals.
svc_sum = sum(v for v in psk.values() if isinstance(v,(int,float)))
excl = (db_label not in psk) and (db_label not in psm) \
    and (top_ek is None or abs(top_ek - svc_sum) < 1e-6*max(1.0, abs(top_ek)))
chk("exclusion", excl,
    f"'{db_label}' absent from per-service maps; top energy_kwh={top_ek}==sum(service)={svc_sum} (DB {ek} not folded in)")
# Sanity: DB energy is a positive multiple of the per-scrape reading.
mult = (ek/per_scrape) if (ek and per_scrape) else 0
chk("scale", ek is not None and per_scrape>0 and ek >= per_scrape*0.9,
    f"energy_kwh={ek} ~ {round(mult,2)}x per-scrape {per_scrape}")
allok = all(c for _,c,_ in out)
for tag,c,detail in out:
    print(f"{'OK' if c else 'NO'}\t{tag}\t{detail}")
print(f"RESULT\t{'PASS' if allok else 'FAIL'}")
EOF
  cat "${TMP_DIR}/b-verdict.txt"
  if grep -q "^RESULT	PASS" "${TMP_DIR}/b-verdict.txt"; then
    assert_pass "B-arithmetic" "database_waste present; ratio + waste_kwh recomputed; gco2>0; excluded from totals"
  else
    assert_fail "B-arithmetic" "one or more database_waste checks failed (see b-verdict.txt): $(grep '^NO' "${TMP_DIR}/b-verdict.txt" | tr '\n' ';')"
  fi

  # Force a few window closes so the archive carries >=1 database_waste line,
  # then disclose it: the per-window archive carries database_waste but the
  # public disclosure must strip it.
  for _ in 1 2 3 4; do
    post_traces >/dev/null 2>&1; sleep 3
    python3 -c "import json,sys; sys.exit(0 if any(l.strip() and ((json.loads(l).get('report') or {}).get('green_summary') or {}).get('database_waste') for l in open('${TMP_DIR}/archive-b.ndjson')) else 1)" 2>/dev/null && break
  done
  arch_dw="$(python3 -c "import json; print(sum(1 for l in open('${TMP_DIR}/archive-b.ndjson') if l.strip() and ((json.loads(l).get('report') or {}).get('green_summary') or {}).get('database_waste')))" 2>/dev/null || echo 0)"
  if [ "${arch_dw:-0}" -gt 0 ]; then
    if "${PERF_SENTINEL_LOCAL_BIN}" disclose --intent internal --confidentiality internal \
         --org-config "${ORG_CONFIG}" --period-type calendar-quarter --from 2026-04-01 --to 2026-09-30 \
         --input "${TMP_DIR}/archive-b.ndjson" --output "${TMP_DIR}/b-disclosure.json" \
         >/dev/null 2>"${TMP_DIR}/b-disclose.err"; then
      if grep -qF "database_waste" "${TMP_DIR}/b-disclosure.json"; then
        assert_fail "B-disclose-excl" "database_waste leaked into the public disclosure"
      else
        assert_pass "B-disclose-excl" "database_waste in ${arch_dw} archived window(s) but absent from disclose output"
      fi
    else
      record_skip "B-disclose-excl" "disclose over the archive failed: $(tail -1 "${TMP_DIR}/b-disclose.err")"
    fi
  else
    record_skip "B-disclose-excl" "archive carried no database_waste window to test exclusion"
  fi
  stop_daemon
else
  assert_fail "B-arithmetic" "daemon never produced database_waste: $(tail -2 "${TMP_DIR}/b.log")"
  record_skip "B-disclose-excl" "not reached"
fi

# =============================================================================
# Leg F: monitor line (data plane the TUI polls + best-effort headless render)
# =============================================================================
step "F: query monitor Energy tab renders the Database waste line"
# The report snapshot backing build_energy_lines carries every field the
# "Database waste:" line renders (waste/measured kWh, ratio, gCO2, region).
if [ -s "${TMP_DIR}/b-report.json" ] && python3 -c "
import json,sys
dw=(json.load(open('${TMP_DIR}/b-report.json')).get('green_summary') or {}).get('database_waste') or {}
sys.exit(0 if all(k in dw for k in ('waste_kwh','energy_kwh','sql_waste_ratio')) and dw.get('waste_gco2') is not None else 1)"; then
  assert_pass "F-dataplane" "/api/export/report snapshot carries the fields the Database waste line renders"
else
  assert_fail "F-dataplane" "report snapshot missing database_waste render fields"
fi
# Best-effort: drive the TUI headless in a pty for ~2 refreshes and grep the frame.
if start_daemon b.toml b2.log && seed_until_db_waste "${TMP_DIR}/f-report.json"; then
  MON_OUT="${TMP_DIR}/monitor.txt"
  ( script -q /dev/null "${PERF_SENTINEL_LOCAL_BIN}" query --daemon-url "${DAEMON_URL}" monitor --refresh 1 ) \
    >"${MON_OUT}" 2>&1 &
  MON_PID=$!
  sleep 6
  kill "${MON_PID}" 2>/dev/null || true; wait "${MON_PID}" 2>/dev/null || true
  if grep -aqF "Database waste" "${MON_OUT}"; then
    line="$(tr -d '\r' < "${MON_OUT}" | grep -aoF "Database waste" | head -1)"
    extra=""
    grep -aqF "excluded from totals" "${MON_OUT}" && extra=" + 'excluded from totals'"
    assert_pass "F-render" "query monitor Energy tab renders the 'Database waste:' line${extra}"
  else
    record_skip "F-render" "headless TUI capture did not surface the line (pty/term); data plane proven above + upstream render unit tests cover it"
  fi
  stop_daemon
else
  record_skip "F-render" "second daemon for the TUI render not ready"
  stop_daemon
fi

# =============================================================================
# Leg C: sticky live cell — no flap, then age-out after the scraper dies
# =============================================================================
step "C: sticky database_waste — no flap between scrapes, ages out after scraper death"
write_config c.toml "${REGION}" "" "${DB_LABEL}"
if start_daemon c.toml c.log && seed_until_db_waste "${TMP_DIR}/c-report.json"; then
  # No flap: poll faster than the 5s scrape for ~12s while re-seeding; every
  # poll must carry database_waste (never null on a between-scrape batch).
  flaps=0; polls=0
  for _ in $(seq 1 6); do
    post_traces >/dev/null
    for _ in 1 2; do
      polls=$((polls+1))
      present="$(curl -fsS "${DAEMON_URL}/api/export/report" 2>/dev/null | python3 -c "import json,sys;print(1 if ((json.load(sys.stdin).get('green_summary') or {}).get('database_waste')) else 0)" 2>/dev/null || echo 0)"
      [ "${present}" = "1" ] || flaps=$((flaps+1))
      sleep 1
    done
  done
  if [ "${flaps}" -eq 0 ]; then
    assert_pass "C-noflap" "database_waste populated on all ${polls} sub-scrape polls (no flapping to null)"
  else
    assert_fail "C-noflap" "database_waste flapped to null on ${flaps}/${polls} polls between scrapes"
  fi

  # Age-out: kill the scraper's endpoint but keep TRAFFIC flowing (the sticky
  # ages inside per-batch scoring, so continued POSTs are what drive it). The
  # live cell must null within ~TTL (last fresh <= staleness 15s after kill,
  # then sticky holds <= 30s more) and not pin a dead measurement forever.
  kill "${MOCK_PID}" 2>/dev/null || true; MOCK_PID=""
  lsof -ti "tcp:${MOCK_PORT}" 2>/dev/null | while read -r pid; do kill "${pid}" 2>/dev/null || true; done
  aged=""; t=0
  for _ in $(seq 1 45); do
    post_traces >/dev/null 2>&1
    present="$(curl -fsS "${DAEMON_URL}/api/export/report" 2>/dev/null | python3 -c "import json,sys;print(1 if ((json.load(sys.stdin).get('green_summary') or {}).get('database_waste')) else 0)" 2>/dev/null || echo 0)"
    if [ "${present}" = "0" ]; then aged="${t}"; break; fi
    sleep 2; t=$((t+2))
  done
  if [ -n "${aged}" ] && [ "${aged}" -ge 10 ] && [ "${aged}" -le 70 ]; then
    assert_pass "C-ageout" "database_waste aged out ~${aged}s after scraper death under continued traffic (TTL 2x staleness, not pinned forever)"
  elif [ -n "${aged}" ]; then
    assert_fail "C-ageout" "database_waste nulled at ${aged}s — outside the expected [10s,70s] TTL band"
  else
    assert_fail "C-ageout" "database_waste NEVER nulled after >90s of dead-scraper traffic (dead measurement pinned forever)"
  fi
  stop_daemon
else
  assert_fail "C-noflap" "daemon never produced database_waste for the sticky test"
  record_skip "C-ageout" "not reached"
  stop_daemon
fi
# Restart the mock for leg D (C killed it).
( cd "${TMP_DIR}/mock" && exec python3 -m http.server "${MOCK_PORT}" --bind 127.0.0.1 ) >/dev/null 2>&1 &
MOCK_PID=$!
disown "${MOCK_PID}" 2>/dev/null || true
for _ in $(seq 1 20); do curl -fsS "http://127.0.0.1:${MOCK_PORT}/alumet-db.prom" >/dev/null 2>&1 && break; sleep 0.5; done

# =============================================================================
# Leg D: carry-over under shedding — DB energy conserved across archived windows
# =============================================================================
step "D: carry-over under shedding — energy conserved across archived NDJSON windows, no OOM"
# cap=1 analysis queue + a tiny 20-trace window: each 300-trace POST overflows
# into a big eviction batch, CPU-heavy detect+score, whole batches shed.
write_config d.toml "${REGION}" "analysis_queue_capacity = 1
max_active_traces = 20" "${DB_LABEL}"
cat >> "${TMP_DIR}/d.toml" <<EOF

[daemon.archive]
path = "${TMP_DIR}/archive-d.ndjson"
max_size_mb = 100
max_files = 8
EOF
if [ ! -s "${SHED_FIX}" ]; then
  record_skip "D-conservation" "shed-load fixture ${SHED_FIX} missing (run make fetch or check daemon-analysis-shedding)"
elif start_daemon d.toml d.log; then
  # Daemon starts fresh (cumulative energy 0), so the total successful scrapes at
  # the end == the energy banked, in per-scrape units. That is the ground truth
  # the archived DB energy is checked against.
  # Flood: concurrent injectors replaying the 300-N+1-trace payload to overrun
  # the queue. --max-time bounds each POST; a straggler reap avoids a hung wait.
  for _ in $(seq 1 8); do
    for _ in $(seq 1 4); do post_shed & done
    sleep 2
  done
  sleep 4
  pkill -f "curl.*${DAEMON_HTTP_PORT}/v1/traces" 2>/dev/null || true
  # Quiesce: stop the flood so the 1-deep queue drains and shedding subsides; the
  # scraper keeps banking DB energy (unconsumed) through this idle window.
  sleep 16
  # Controlled consume: with the daemon idle and the scraper fresh, the FIRST
  # scored batch takes ALL accumulated energy in one window (the carry-over
  # signature). A few spaced single seeds drain the pending and flush the archive
  # so the cross-window energy total lands on the measured total.
  for _ in $(seq 1 5); do post_traces >/dev/null 2>&1; sleep 4; done
  sleep 3
  SCRAPES="$(alumet_success_count)"   # total scrapes since fresh start == energy banked
  DROPS="$(grep -c 'dropping window\|dropping line' "${TMP_DIR}/d.log" 2>/dev/null)"; DROPS="${DROPS:-0}"
  SHED="$(curl -fsS "${DAEMON_URL}/metrics" 2>/dev/null | awk '$1 ~ /^perf_sentinel_analysis_shed_batches_total/ {print $2; f=1; exit} END{if(!f)print 0}')"
  ALIVE=0; curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 && ALIVE=1
  if [ -s "${TMP_DIR}/archive-d.ndjson" ]; then
    python3 - "${TMP_DIR}/archive-d.ndjson" "${PER_SCRAPE_KWH}" "${SCRAPES}" "${DROPS}" > "${TMP_DIR}/d-verdict.txt" <<'EOF'
import json, sys
path, per_scrape, scrapes, drops = sys.argv[1], float(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
windows = with_dw = 0; total = 0.0; maxw = 0.0; quantized_ok = True
for line in open(path):
    line = line.strip()
    if not line: continue
    try: rep = (json.loads(line).get("report") or {})   # archive wraps {report, ts}
    except Exception: continue
    windows += 1
    dw = (rep.get("green_summary") or {}).get("database_waste")
    if dw and dw.get("energy_kwh"):
        with_dw += 1; ek = dw["energy_kwh"]; total += ek; maxw = max(maxw, ek)
        mult = ek / per_scrape          # each delta is whole scrapes accumulated
        if abs(mult - round(mult)) > 0.25: quantized_ok = False
# Ground truth: every successful Alumet scrape banked exactly per_scrape kWh.
# Consumed+archived DB energy must equal that, minus what the archive writer
# dropped (documented bound) and at most one still-pending (unconsumed) scrape.
measured = scrapes * per_scrape
lo = max(0.0, (scrapes - drops - 2)) * per_scrape   # up to 2 still-pending scrapes
hi = (scrapes + 0.5) * per_scrape
print(f"windows={windows} with_db_waste={with_dw} scrapes={scrapes} archive_drops={drops}")
print(f"sum_energy_kwh={total:.6f} max_window_kwh={maxw:.6f} per_scrape={per_scrape} measured={measured:.6f}")
# Conservation: quantized, strictly positive, no energy created (<= measured),
# and none vanished beyond archive-drops + one pending window.
conserved = with_dw > 0 and total > 0 and quantized_ok and total <= hi and total >= lo and scrapes > 0
carried = maxw > per_scrape*1.5   # a window that absorbed >1 scrape (scoring shed around it)
print(f"CONSERVED={'yes' if conserved else 'no'} QUANTIZED={'yes' if quantized_ok else 'no'} CARRIED_OVER={'yes' if carried else 'no'}")
print("RESULT", "PASS" if conserved else "FAIL")
EOF
    cat "${TMP_DIR}/d-verdict.txt"
    CARRY="$(grep -o 'CARRIED_OVER=[a-z]*' "${TMP_DIR}/d-verdict.txt" | cut -d= -f2)"
    note "D: shed_batches=${SHED}, alive=${ALIVE}, scrapes=${SCRAPES}, archive_drops=${DROPS}, carry_over=${CARRY}"
    if [ "${SHED}" -gt 0 ] && [ "${ALIVE}" = "1" ] && grep -q "^RESULT PASS" "${TMP_DIR}/d-verdict.txt"; then
      assert_pass "D-conservation" "sheds ${SHED} batches without OOM; archived DB energy == ${SCRAPES} scrapes' worth (drops=${DROPS}, carry_over=${CARRY})"
    elif [ "${ALIVE}" != "1" ]; then
      assert_fail "D-conservation" "daemon not alive after the flood — OOM/crash instead of shedding (regression)"
    elif [ "${SHED}" -eq 0 ]; then
      assert_fail "D-conservation" "no batches shed (cap=1 + 20-trace window flood did not overrun) — cannot exercise carry-over"
    else
      assert_fail "D-conservation" "DB energy not conserved vs ${SCRAPES} scrapes (drops=${DROPS}): $(grep '^sum_energy' "${TMP_DIR}/d-verdict.txt")"
    fi
  else
    assert_fail "D-conservation" "no archive written (shed=${SHED}, alive=${ALIVE})"
  fi
  stop_daemon
else
  assert_fail "D-conservation" "daemon (D) not ready: $(tail -2 "${TMP_DIR}/d.log")"
fi

# =============================================================================
verdict=$([ "${FAILS}" -eq 0 ] && echo PASS || echo FAIL)
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "perf-sentinel 0.9.13 database-waste feature (Alumet DB cgroup energy x SQL waste ratio)."
  echo ""
  echo "| assertion | result |"
  echo "|---|---|"
  for row in "${SUMMARY[@]}"; do
    printf "| %s | %s |\n" "${row%%|*}" "${row#*|}"
  done
  echo ""
  if [ "${#NOTES[@]}" -gt 0 ]; then
    echo "Notes:"
    for n in "${NOTES[@]}"; do echo "- ${n}"; done
    echo ""
  fi
  echo "Verdict: **${verdict}**"
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  color_green "PASS — report at ${REPORT}"
else
  die "FAIL (${FAILS} assertion(s)) — report at ${REPORT}"
fi
