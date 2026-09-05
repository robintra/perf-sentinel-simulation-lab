#!/usr/bin/env bash
# incident-window-capture: the 0.20.0 incident intake, and the only question a
# post-mortem ever asks of perf-sentinel: what was already burning on this
# service in the minutes before it was OOM-killed.
#
# perf-sentinel cannot see an observed service's memory and cannot detect a
# crash: there is no OTLP metrics path, `SpanEvent` carries no status, and a
# saturating process keeps emitting spans, more slowly. The operator's
# alerting owns the moment. What perf-sentinel owns is the findings of a
# period, and it is the only thing that can freeze them before the FIFO ring
# evicts them, which on a busy fleet takes minutes. By the time a human opens
# a terminal the window is usually gone.
#
# Legs, each closing a hole the design has to defend:
#
#   A. Freeze at reception. A `firing` Alertmanager envelope is accepted and
#      the findings of `[at_ms - lookback_ms, at_ms + 2 * trace_ttl_ms]` are
#      captured on the spot. The window closes AFTER the incident on purpose:
#      a finding is stamped when its trace is analysed, one TTL after its last
#      span, so the traces live at the crash land past `startsAt`.
#   B. The settle pass grows the record. Traces live at the incident are
#      analysed after the reception freeze. One TTL past the window's close a
#      settle re-resolves the same window and merges by signature. The
#      assertion is not "the count changed", it is that the row captured at
#      reception is STILL there next to the new one: a merge that replaced the
#      capture would also read as 2 rows on a lucky day.
#   C. Idempotence and the end. A repost is the same incident, not a second
#      one, and does not re-freeze. An `endsAt` before `startsAt` is not an
#      end and does not seal the record against the corrected delivery.
#   D. Refusals are counted. The intake body says what a delivery did, but
#      Alertmanager discards it and never retries a 4xx, so a receiver with
#      the wrong header or a rule with the wrong label loses every capture in
#      silence. `perf_sentinel_incidents_rejected_total{reason}` is the only
#      signal, and a counter that appears once it fires cannot be alerted on,
#      so the pre-warm is part of the contract. `[daemon] read_api_key` opens
#      the GET and never the POST: a delivery signed with the read key is
#      refused and counted like a bare one.
#   E. Durability. The ring dies with the daemon, and a node-level memory event
#      often takes a co-located daemon with it: the record that explains the
#      outage is destroyed by the outage. The NDJSON archive is written by one
#      task opened at startup, owner-only, one line per record, and a symlinked
#      path fails the daemon rather than the first incident.
#   F. The window form of `/api/findings`. `until_ms` folds over the
#      detections inside the window alone, so `seen_count` describes the
#      window, and `/api/status` reports `oldest_finding_ms`, which is what
#      separates "nothing fired" from "the ring no longer reaches that far
#      back". Those two answers were indistinguishable before 0.20.0.
#   G. `perf_sentinel_service_last_span_timestamp_seconds{service}`, the
#      Unix stamp of the last span admitted per service. `time() - gauge` is
#      an age that survives a daemon restart, where every counter resets to
#      zero and a whole fleet looks stopped.
#
# Local binary, no cluster.

set -uo pipefail
# Job control off: the shell would otherwise print "Terminated" of its own
# every time the daemon is killed, which reads like a failure mid-scenario.
set +m

SCENARIO="incident-window-capture"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
# Short on purpose: the daemon's JSON socket lives here and a Unix socket path
# is capped near 104 bytes.
TMP_DIR="/tmp/iwc"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
HTTP_PORT="${IWC_HTTP_PORT:-14560}"
GRPC_PORT="${IWC_GRPC_PORT:-14561}"
# The settle fires at `at_ms + 3 * trace_ttl_ms`, so the TTL sets the length of
# the scenario. 2 s leaves a trace analysed between +2 s and +3 s comfortably
# inside a window that closes at +4 s.
TTL_MS="${IWC_TTL_MS:-2000}"
API_KEY="lab-incident-key"
# The read key must differ from the write key, the daemon refuses them equal.
READ_KEY="lab-read-key-0000"

rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
fail() { color_red   "    fail: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

DAEMON_PID=""
cleanup() {
  [ -n "${DAEMON_PID}" ] && kill -9 "${DAEMON_PID}" 2>/dev/null || true
}
trap cleanup EXIT

declare -a NAMES=() VERDICTS=() NOTES=()
record() { NAMES+=("$1"); VERDICTS+=("$2"); NOTES+=("$3"); }

step "0. Pre-flight"
command -v python3 >/dev/null || die "python3 not on PATH"
command -v curl >/dev/null || die "curl not on PATH"
[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] \
  || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release first)"
ok "local binary at ${PERF_SENTINEL_LOCAL_BIN}"

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
# RFC 3339 with milliseconds: a stamp truncated to the second lands up to a
# second away from the findings it is meant to bracket.
rfc3339() {
  python3 -c "
import datetime, sys
ms = int(sys.argv[1])
print(datetime.datetime.fromtimestamp(ms / 1000, datetime.timezone.utc)
      .strftime('%Y-%m-%dT%H:%M:%S.') + f'{ms % 1000:03d}Z')
" "$1"
}

# One trace of 8 sibling SELECTs on the same template: an n+1 over the
# configured floor of 5. $1 = table, $2 = endpoint, $3 = trace suffix.
cat > "${TMP_DIR}/seed.py" <<'PY'
import json, socket, sys
from datetime import datetime, timezone

sock_path, table, endpoint, suffix = sys.argv[1:5]
now = datetime.now(timezone.utc)
ts = now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"
# One trace id for the whole batch: siblings in separate traces are not an
# n+1, they are eight unrelated queries.
tid = (f"iwc{suffix}" + "0" * 29)[:32]
events = [{
    "timestamp": ts, "trace_id": tid, "span_id": f"s{i:015d}",
    "service": "shop-svc", "cloud_region": "eu-west-3",
    "type": "sql", "operation": "SELECT",
    "target": f"SELECT * FROM {table} WHERE owner_id = {i}",
    "duration_us": 1500,
    "source": {"endpoint": endpoint, "method": "ShopService::list"},
} for i in range(1, 9)]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock_path)
s.sendall((json.dumps(events) + "\n").encode())
s.close()
PY

seed() { python3 "${TMP_DIR}/seed.py" "${TMP_DIR}/s" "$1" "$2" "$3"; }

write_config() {  # $1 = incident archive path
  cat > "${TMP_DIR}/cfg.toml" <<EOF
[green]
enabled = true
default_region = "FR"

[daemon]
listen_address = "127.0.0.1"
listen_port_http = ${HTTP_PORT}
listen_port_grpc = ${GRPC_PORT}
api_enabled = true
json_socket = "${TMP_DIR}/s"
trace_ttl_ms = ${TTL_MS}
environment = "staging"
read_api_key = "${READ_KEY}"

[daemon.ack]
enabled = false

[daemon.incidents]
enabled = true
api_key = "${API_KEY}"
lookback_ms = 300000
max_retained = 200
archive_path = "$1"

[detection]
n_plus_one_min_occurrences = 5
EOF
}

start_daemon() {  # $1 = log name
  rm -f "${TMP_DIR}/s"
  "${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/cfg.toml" > "${TMP_DIR}/$1" 2>&1 &
  DAEMON_PID=$!
  for _ in $(seq 1 40); do
    [ -S "${TMP_DIR}/s" ] && return 0
    kill -0 "${DAEMON_PID}" 2>/dev/null || return 1
    sleep 0.25
  done
  return 1
}

stop_daemon() {
  [ -n "${DAEMON_PID}" ] && { kill -9 "${DAEMON_PID}" 2>/dev/null; wait "${DAEMON_PID}" 2>/dev/null; }
  DAEMON_PID=""
}

api() {  # $1 = method, $2 = path, $3 = body ("" for none), $4 = key ("" for none)
  local args=(-s -o "${TMP_DIR}/body" -w '%{http_code}' -X "$1")
  [ -n "${3:-}" ] && args+=(-H "content-type: application/json" -d "$3")
  [ -n "${4:-}" ] && args+=(-H "X-API-Key: $4")
  curl "${args[@]}" "http://127.0.0.1:${HTTP_PORT}$2"
}

# One alert as Alertmanager posts it. $1 = status, $2 = startsAt, $3 = endsAt.
alert_body() {
  python3 -c "
import json, sys
status, starts, ends = sys.argv[1:4]
print(json.dumps({'version': '4', 'alerts': [{
    'status': status,
    'labels': {'service': ' shop-svc ', 'perf_sentinel_kind': 'oom_kill', 'namespace': 'shop'},
    'annotations': {'summary': 'container memory limit reached'},
    'startsAt': starts, 'endsAt': ends,
}]}))
" "$1" "$2" "$3"
}

jqp() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

metric() {  # $1 = full metric selector, prints the value or "absent"
  curl -s "http://127.0.0.1:${HTTP_PORT}/metrics" \
    | awk -v m="$1" 'index($0, m) == 1 {print $2; found=1} END {if (!found) print "absent"}'
}

# === Startup, and the two pre-warms ===
step "1. Daemon up, refusal and kind counters pre-warmed at zero"
write_config "${TMP_DIR}/incidents.ndjson"
start_daemon "d.log" || die "daemon did not start: $(tail -5 "${TMP_DIR}/d.log")"

# /api/config says which gates are up, without the keys themselves.
CFG="$(curl -s "http://127.0.0.1:${HTTP_PORT}/api/config")"
CFG_READ="$(echo "${CFG}" | jqp "str(d.get('read_api_key_set', 'absent')).lower()")"
CFG_INC="$(echo "${CFG}" | jqp "str(d.get('incidents_enabled', 'absent')).lower()")"
# The keys themselves must never appear: the surface summarises them to
# booleans, and a leak here would be a leak on every dashboard that reads it.
if echo "${CFG}" | grep -q -e "${API_KEY}" -e "${READ_KEY}"; then
  CFG_READ="leaked"
fi
if [ "${CFG_READ}" = "true" ] && [ "${CFG_INC}" = "true" ]; then
  ok "/api/config reports read_api_key_set=true and incidents_enabled=true, neither key echoed"
  record "config reports the gates" PASS "read_api_key_set=true, incidents_enabled=true, keys absent"
else
  fail "/api/config: read_api_key_set=${CFG_READ}, incidents_enabled=${CFG_INC}"
  record "config reports the gates" FAIL "read_api_key_set=${CFG_READ}, incidents_enabled=${CFG_INC}"
fi

PREWARM_OK=1
PREWARM_NOTE=""
for r in unauthorized no_service unparsable_time overflow; do
  v="$(metric "perf_sentinel_incidents_rejected_total{reason=\"${r}\"}")"
  [ "${v}" = "0" ] || { PREWARM_OK=0; PREWARM_NOTE="${PREWARM_NOTE}${r}=${v} "; }
done
for k in oom_kill memory_saturation restart deploy other; do
  v="$(metric "perf_sentinel_incidents_total{kind=\"${k}\"}")"
  [ "${v}" = "0" ] || { PREWARM_OK=0; PREWARM_NOTE="${PREWARM_NOTE}kind:${k}=${v} "; }
done
if [ "${PREWARM_OK}" = "1" ]; then
  ok "4 refusal reasons and 5 incident kinds all present at 0"
  record "counters pre-warmed" PASS "4 reasons + 5 kinds at 0"
else
  fail "not pre-warmed: ${PREWARM_NOTE}(absent = the series only appears once it fires)"
  record "counters pre-warmed" FAIL "${PREWARM_NOTE}"
fi

# Archive opened at startup, before any incident: a bad path must fail the
# daemon, not the first delivery, and the file must not be world-readable.
if [ -f "${TMP_DIR}/incidents.ndjson" ]; then
  MODE="$(stat -f '%Lp' "${TMP_DIR}/incidents.ndjson" 2>/dev/null || stat -c '%a' "${TMP_DIR}/incidents.ndjson")"
  if [ "${MODE}" = "600" ]; then
    ok "archive created at startup with mode 0600"
    record "archive opened at startup" PASS "mode 0600 before any incident"
  else
    fail "archive mode is ${MODE}, expected 600"
    record "archive opened at startup" FAIL "mode ${MODE}"
  fi
else
  fail "no archive file after startup, it is opened lazily"
  record "archive opened at startup" FAIL "file absent"
fi

# === Leg A: the freeze at reception ===
step "A. A firing alert freezes the findings of its window"
seed orders "GET /orders" a
sleep $(python3 -c "print(${TTL_MS} / 1000 * 2)")
FINDINGS_BEFORE="$(curl -s "http://127.0.0.1:${HTTP_PORT}/api/findings" | jqp 'len(d)')"
[ "${FINDINGS_BEFORE}" -ge 1 ] || die "no finding in the ring before the incident, the seed did not analyse"
ok "${FINDINGS_BEFORE} finding(s) in the ring before the alert"

AT_MS="$(now_ms)"
STARTS="$(rfc3339 "${AT_MS}")"
CODE="$(api POST /api/incidents "$(alert_body firing "${STARTS}" "0001-01-01T00:00:00Z")" "${API_KEY}")"
INTAKE="$(cat "${TMP_DIR}/body")"
# The second seed goes in immediately: analysed one TTL from now, so after the
# reception freeze and inside the window that closes at +2 TTL.
seed invoices "GET /invoices" b

if [ "${CODE}" = "200" ] && [ "$(echo "${INTAKE}" | jqp "d['recorded']")" = "1" ]; then
  ok "delivery accepted, recorded=1 (${INTAKE})"
  record "firing alert recorded" PASS "recorded=1"
else
  fail "HTTP ${CODE}, body ${INTAKE}"
  record "firing alert recorded" FAIL "HTTP ${CODE}"
fi

api GET /api/incidents "" "${API_KEY}" >/dev/null
CAP="$(cat "${TMP_DIR}/body")"
INC_SERVICE="$(echo "${CAP}" | jqp "d[0]['service']")"
WIN_FROM="$(echo "${CAP}" | jqp "d[0]['window_from_ms']")"
WIN_TO="$(echo "${CAP}" | jqp "d[0]['window_to_ms']")"
INC_AT="$(echo "${CAP}" | jqp "d[0]['at_ms']")"
FROZEN_A="$(echo "${CAP}" | jqp "len(d[0]['findings'])")"
SIG_A="$(echo "${CAP}" | jqp "d[0]['findings'][0]['finding']['signature']")"
OLDEST="$(echo "${CAP}" | jqp "d[0].get('oldest_finding_ms', 'absent')")"

EXPECT_FROM=$((INC_AT - 300000))
EXPECT_TO=$((INC_AT + 2 * TTL_MS))
if [ "${INC_SERVICE}" = "shop-svc" ] && [ "${WIN_FROM}" = "${EXPECT_FROM}" ] && [ "${WIN_TO}" = "${EXPECT_TO}" ]; then
  ok "window is [at - lookback, at + 2 x ttl], and the padded label was trimmed to '${INC_SERVICE}'"
  record "window bounds and label trim" PASS "[${WIN_FROM}, ${WIN_TO}], service '${INC_SERVICE}'"
else
  fail "service '${INC_SERVICE}', window [${WIN_FROM}, ${WIN_TO}], expected [${EXPECT_FROM}, ${EXPECT_TO}]"
  record "window bounds and label trim" FAIL "[${WIN_FROM}, ${WIN_TO}] vs [${EXPECT_FROM}, ${EXPECT_TO}]"
fi

if [ "${FROZEN_A}" -ge 1 ] && [ "${OLDEST}" != "absent" ] && [ "${OLDEST}" -ge "${WIN_FROM}" ]; then
  ok "${FROZEN_A} finding(s) frozen at reception, oldest_finding_ms=${OLDEST} above window_from: the capture is complete"
  record "freeze at reception" PASS "${FROZEN_A} finding(s), oldest above window_from"
else
  fail "frozen=${FROZEN_A}, oldest_finding_ms=${OLDEST}, window_from=${WIN_FROM}"
  record "freeze at reception" FAIL "frozen=${FROZEN_A}, oldest=${OLDEST}"
fi

if [ "$(echo "${CAP}" | jqp "d[0].get('detail', 'absent')")" = "container memory limit reached" ]; then
  ok "the summary annotation reached the record as detail"
  record "annotation kept" PASS "detail from summary"
else
  fail "detail is $(echo "${CAP}" | jqp "d[0].get('detail', 'absent')")"
  record "annotation kept" FAIL "detail missing"
fi

if [ "$(echo "${CAP}" | jqp "d[0].get('namespace', 'absent')")" = "shop" ]; then
  ok "the namespace label reached the record"
  record "namespace kept" PASS "namespace from the alert label"
else
  fail "namespace is $(echo "${CAP}" | jqp "d[0].get('namespace', 'absent')")"
  record "namespace kept" FAIL "namespace missing"
fi

# === Leg B: the settle grows the record ===
step "B. The settle pass merges the traces live at the incident"
# Settle is due at at_ms + 3 x ttl. Wait past it from the stamp itself, not
# from here, so the leg does not drift with the time legs A spent on curl.
SLEEP_S="$(python3 -c "
import time
due = (${AT_MS} + 3 * ${TTL_MS} + 1500) / 1000
print(max(0.0, due - time.time()))
")"
sleep "${SLEEP_S}"

api GET /api/incidents "" "${API_KEY}" >/dev/null
SETTLED="$(cat "${TMP_DIR}/body")"
FROZEN_B="$(echo "${SETTLED}" | jqp "len(d[0]['findings'])")"
KEPT="$(echo "${SETTLED}" | jqp "sum(1 for f in d[0]['findings'] if f['finding']['signature'] == '${SIG_A}')")"
INCIDENT_COUNT="$(echo "${SETTLED}" | jqp 'len(d)')"

if [ "${FROZEN_B}" -gt "${FROZEN_A}" ] && [ "${KEPT}" = "1" ]; then
  ok "the record grew from ${FROZEN_A} to ${FROZEN_B} rows and the reception row is still there"
  record "settle merges, never loses" PASS "${FROZEN_A} -> ${FROZEN_B} rows, first row kept"
else
  fail "rows ${FROZEN_A} -> ${FROZEN_B}, the reception signature appears ${KEPT} time(s)"
  fail "a settle that replaced the capture would also read as a row count that moved"
  record "settle merges, never loses" FAIL "${FROZEN_A} -> ${FROZEN_B}, kept=${KEPT}"
fi

if [ "${INCIDENT_COUNT}" = "1" ] && [ "$(metric 'perf_sentinel_incidents_total{kind="oom_kill"}')" = "1" ]; then
  ok "still one incident, and the kind counter counts incidents, not deliveries"
  record "one incident, one count" PASS "1 record, incidents_total{oom_kill}=1"
else
  fail "${INCIDENT_COUNT} incident(s), incidents_total{oom_kill}=$(metric 'perf_sentinel_incidents_total{kind="oom_kill"}')"
  record "one incident, one count" FAIL "${INCIDENT_COUNT} record(s)"
fi

# === Leg C: idempotence, and what counts as an end ===
step "C. A repost is the same incident, and an end before the start is not an end"
api POST /api/incidents "$(alert_body firing "${STARTS}" "0001-01-01T00:00:00Z")" "${API_KEY}" >/dev/null
REPEAT="$(cat "${TMP_DIR}/body")"
api GET /api/incidents "" "${API_KEY}" >/dev/null
AFTER_REPEAT="$(cat "${TMP_DIR}/body")"
ROWS_AFTER_REPEAT="$(echo "${AFTER_REPEAT}" | jqp "len(d[0]['findings'])")"

if [ "$(echo "${REPEAT}" | jqp "d['repeated']")" = "1" ] \
   && [ "$(echo "${REPEAT}" | jqp "d['recorded']")" = "0" ] \
   && [ "${ROWS_AFTER_REPEAT}" = "${FROZEN_B}" ]; then
  ok "repeated=1, recorded=0, and the ${FROZEN_B} settled rows were not re-frozen away"
  record "repost is idempotent" PASS "repeated=1, rows unchanged at ${FROZEN_B}"
else
  fail "body ${REPEAT}, rows ${ROWS_AFTER_REPEAT} (settled: ${FROZEN_B})"
  record "repost is idempotent" FAIL "${REPEAT}, rows ${ROWS_AFTER_REPEAT}"
fi

# Alertmanager's zero time is not the only bad end: a clock-skewed resolve
# sends one before the start. Sealing it would refuse the corrected delivery.
api POST /api/incidents "$(alert_body resolved "${STARTS}" "1970-01-01T00:00:00.000Z")" "${API_KEY}" >/dev/null
api GET /api/incidents "" "${API_KEY}" >/dev/null
BAD_END="$(cat "${TMP_DIR}/body" | jqp "d[0].get('ended_at_ms', 'absent')")"

END_MS=$((INC_AT + 45000))
api POST /api/incidents "$(alert_body resolved "${STARTS}" "$(rfc3339 ${END_MS})")" "${API_KEY}" >/dev/null
api GET /api/incidents "" "${API_KEY}" >/dev/null
GOOD_END="$(cat "${TMP_DIR}/body" | jqp "d[0].get('ended_at_ms', 'absent')")"

if [ "${BAD_END}" = "absent" ] && [ "${GOOD_END}" = "${END_MS}" ]; then
  ok "an endsAt before startsAt left the incident open, the later valid one closed it"
  record "end before start refused" PASS "still open, then ended_at_ms=${GOOD_END}"
else
  fail "after the bogus resolve: ${BAD_END}, after the valid one: ${GOOD_END} (expected ${END_MS})"
  record "end before start refused" FAIL "${BAD_END} then ${GOOD_END}"
fi

# === Leg F: the window form of the findings listing ===
step "F. until_ms bounds the listing, and /api/status says how far back the ring reaches"
WINDOW_ONLY="$(curl -s "http://127.0.0.1:${HTTP_PORT}/api/findings?since_ms=${EXPECT_FROM}&until_ms=${AT_MS}" | jqp 'len(d)')"
WHOLE="$(curl -s "http://127.0.0.1:${HTTP_PORT}/api/findings" | jqp 'len(d)')"
if [ "${WINDOW_ONLY}" -lt "${WHOLE}" ] && [ "${WINDOW_ONLY}" -ge 1 ]; then
  ok "a window closed at the incident holds ${WINDOW_ONLY} of the ${WHOLE} folded rows"
  record "until_ms bounds the fold" PASS "${WINDOW_ONLY} of ${WHOLE} rows inside the window"
else
  fail "window=${WINDOW_ONLY}, whole buffer=${WHOLE}: an upper bound applied after the fold would keep both"
  record "until_ms bounds the fold" FAIL "${WINDOW_ONLY} vs ${WHOLE}"
fi

STATUS_OLDEST="$(curl -s "http://127.0.0.1:${HTTP_PORT}/api/status" | jqp "d.get('oldest_finding_ms', 'absent')")"
if [ "${STATUS_OLDEST}" != "absent" ] && [ "${STATUS_OLDEST}" -gt 0 ]; then
  ok "oldest_finding_ms=${STATUS_OLDEST} on /api/status: an empty window can be told from an evicted one"
  record "oldest_finding_ms on status" PASS "${STATUS_OLDEST}"
else
  fail "oldest_finding_ms is ${STATUS_OLDEST}"
  record "oldest_finding_ms on status" FAIL "${STATUS_OLDEST}"
fi

# === Leg G: the per-service last-span gauge ===
step "G. The last-span gauge publishes a fact, not an opinion"
GAUGE="$(metric 'perf_sentinel_service_last_span_timestamp_seconds{service="shop-svc"}')"
AGE="$(python3 -c "
import time, sys
v = sys.argv[1]
print('absent' if v == 'absent' else int(time.time() - float(v)))
" "${GAUGE}")"
if [ "${AGE}" != "absent" ] && [ "${AGE}" -ge 0 ] && [ "${AGE}" -lt 120 ]; then
  ok "shop-svc last emitted a span ${AGE}s ago (a Unix stamp, so time() - gauge is the age)"
  record "last-span gauge" PASS "age ${AGE}s"
else
  fail "gauge=${GAUGE}, age=${AGE}"
  record "last-span gauge" FAIL "gauge ${GAUGE}"
fi

# === Leg D: every refusal counted ===
step "D. Refusals are counted, the 401 included"
CODE_401="$(api POST /api/incidents "$(alert_body firing "${STARTS}" "0001-01-01T00:00:00Z")" "")"
CODE_401_GET="$(api GET /api/incidents "" "")"
# The read key: the GET opens, the same delivery is refused and counted.
CODE_READ_GET="$(api GET /api/incidents "" "${READ_KEY}")"
CODE_READ_POST="$(api POST /api/incidents "$(alert_body firing "${STARTS}" "0001-01-01T00:00:00Z")" "${READ_KEY}")"
# The namespace filter under the read key: the label narrows the listing, and
# an unknown one is an empty list, never a refusal.
api GET "/api/incidents?namespace=shop" "" "${READ_KEY}" >/dev/null
NS_HIT="$(jqp 'len(d)' < "${TMP_DIR}/body")"
api GET "/api/incidents?namespace=nowhere" "" "${READ_KEY}" >/dev/null
NS_MISS="$(jqp 'len(d)' < "${TMP_DIR}/body")"

NO_SVC_BODY='{"version":"4","alerts":[{"status":"firing","labels":{"perf_sentinel_kind":"restart"},"startsAt":"'"${STARTS}"'"}]}'
api POST /api/incidents "${NO_SVC_BODY}" "${API_KEY}" >/dev/null
NO_SVC="$(cat "${TMP_DIR}/body")"

BAD_TIME_BODY='{"version":"4","alerts":[{"status":"firing","labels":{"service":"shop-svc","perf_sentinel_kind":"restart"},"startsAt":"yesterday"}]}'
api POST /api/incidents "${BAD_TIME_BODY}" "${API_KEY}" >/dev/null
BAD_TIME="$(cat "${TMP_DIR}/body")"

# 1001 alerts, all without a service: the cap sheds the last one and the
# thousand that are read are refused without paying a single fold.
python3 -c "
import json
alerts = [{'status': 'firing', 'labels': {'perf_sentinel_kind': 'restart'},
           'startsAt': '2026-09-01T14:00:00.000Z'} for _ in range(1001)]
print(json.dumps({'version': '4', 'alerts': alerts}))
" > "${TMP_DIR}/overflow.json"
OVER_CODE="$(curl -s -o "${TMP_DIR}/body" -w '%{http_code}' -X POST \
  -H "content-type: application/json" -H "X-API-Key: ${API_KEY}" \
  --data-binary "@${TMP_DIR}/overflow.json" \
  "http://127.0.0.1:${HTTP_PORT}/api/incidents")"
OVER="$(cat "${TMP_DIR}/body")"

M_UNAUTH="$(metric 'perf_sentinel_incidents_rejected_total{reason="unauthorized"}')"
M_NOSVC="$(metric 'perf_sentinel_incidents_rejected_total{reason="no_service"}')"
M_TIME="$(metric 'perf_sentinel_incidents_rejected_total{reason="unparsable_time"}')"
M_OVER="$(metric 'perf_sentinel_incidents_rejected_total{reason="overflow"}')"

if [ "${CODE_401}" = "401" ] && [ "${CODE_401_GET}" = "401" ] && [ "${M_UNAUTH}" = "3" ]; then
  ok "POST and GET both answer 401 without the key, and every refusal is counted"
  record "401 counted" PASS "unauthorized=3 (bare POST + bare GET + read-key POST)"
else
  fail "POST ${CODE_401}, GET ${CODE_401_GET}, unauthorized=${M_UNAUTH} (expected 3)"
  record "401 counted" FAIL "${CODE_401}/${CODE_401_GET}, counter ${M_UNAUTH}"
fi

if [ "${CODE_READ_GET}" = "200" ] && [ "${CODE_READ_POST}" = "401" ]; then
  ok "the read key answers 200 on GET /api/incidents and 401 on the POST"
  record "read key reads, never writes" PASS "GET 200, POST 401"
else
  fail "with the read key: GET ${CODE_READ_GET}, POST ${CODE_READ_POST}"
  record "read key reads, never writes" FAIL "GET ${CODE_READ_GET}, POST ${CODE_READ_POST}"
fi

if [ "${NS_HIT}" -ge 1 ] && [ "${NS_MISS}" = "0" ]; then
  ok "namespace=shop lists ${NS_HIT} incident(s), namespace=nowhere lists none"
  record "namespace filter" PASS "shop=${NS_HIT}, nowhere=0"
else
  fail "namespace=shop -> ${NS_HIT}, namespace=nowhere -> ${NS_MISS}"
  record "namespace filter" FAIL "shop=${NS_HIT}, nowhere=${NS_MISS}"
fi

# no_service: 1 from the single bad alert, 1000 from the overflow delivery.
if [ "$(echo "${NO_SVC}" | jqp "d['rejected_no_service']")" = "1" ] \
   && [ "$(echo "${BAD_TIME}" | jqp "d['rejected_unparsable_time']")" = "1" ] \
   && [ "${OVER_CODE}" = "200" ] \
   && [ "$(echo "${OVER}" | jqp "d['rejected_overflow']")" = "1" ] \
   && [ "${M_NOSVC}" = "1001" ] && [ "${M_TIME}" = "1" ] && [ "${M_OVER}" = "1" ]; then
  ok "no_service=${M_NOSVC} (1 alert + 1000 read past the cap), unparsable_time=1, overflow=1"
  record "alert refusals counted" PASS "no_service=1001, unparsable_time=1, overflow=1"
else
  fail "bodies ${NO_SVC} / ${BAD_TIME} / ${OVER} (HTTP ${OVER_CODE})"
  fail "counters no_service=${M_NOSVC}, unparsable_time=${M_TIME}, overflow=${M_OVER}"
  record "alert refusals counted" FAIL "${M_NOSVC}/${M_TIME}/${M_OVER}"
fi

# === Leg E: the archive on disk ===
step "E. The archive holds every record, and a symlinked path fails the daemon"
stop_daemon
ARCHIVE="${TMP_DIR}/incidents.ndjson"
LINES="$(wc -l < "${ARCHIVE}" | tr -d ' ')"
ARCHIVE_READ="$(python3 -c "
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
ids = {r['id'] for r in rows}
counts = [len(r['findings']) for r in rows]
ended = [('ended_at_ms' in r) for r in rows]
print(len(rows), len(ids), max(counts) if counts else 0, sum(ended))
" "${ARCHIVE}")"
read -r A_ROWS A_IDS A_MAXF A_ENDED <<< "${ARCHIVE_READ}"

# A record per new incident, per settle and per close, all under one id, the
# last one carrying the end. Every line parses: two writers would tear one.
if [ "${A_ROWS}" -ge 3 ] && [ "${A_IDS}" = "1" ] && [ "${A_MAXF}" -ge "${FROZEN_B}" ] && [ "${A_ENDED}" -ge 1 ]; then
  ok "${A_ROWS} intact lines, one incident id, up to ${A_MAXF} findings, ${A_ENDED} carrying an end"
  record "archive complete and intact" PASS "${A_ROWS} lines, 1 id, max ${A_MAXF} findings"
else
  fail "lines=${A_ROWS} (raw ${LINES}), ids=${A_IDS}, max findings=${A_MAXF}, ended=${A_ENDED}"
  record "archive complete and intact" FAIL "${A_ROWS}/${A_IDS}/${A_MAXF}/${A_ENDED}"
fi

ln -s "${TMP_DIR}/real-target.ndjson" "${TMP_DIR}/linked.ndjson"
write_config "${TMP_DIR}/linked.ndjson"
rm -f "${TMP_DIR}/s"
"${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/cfg.toml" > "${TMP_DIR}/d-symlink.log" 2>&1
SYMLINK_RC=$?
if [ "${SYMLINK_RC}" != "0" ] && grep -qi "symlink" "${TMP_DIR}/d-symlink.log"; then
  ok "a symlinked archive_path refuses startup (rc=${SYMLINK_RC}), it is not discovered at the first incident"
  record "symlinked archive refused" PASS "rc=${SYMLINK_RC}, refusal names the symlink"
else
  fail "rc=${SYMLINK_RC}, log: $(tail -3 "${TMP_DIR}/d-symlink.log")"
  record "symlinked archive refused" FAIL "rc=${SYMLINK_RC}"
fi

# === Report ===
{
  echo "# Scenario: ${SCENARIO}"
  echo
  echo "Binary: \`${PERF_SENTINEL_LOCAL_BIN}\`"
  echo
  echo "| Sub-test | Verdict | Note |"
  echo "| --- | --- | --- |"
  for i in "${!NAMES[@]}"; do
    echo "| ${NAMES[$i]} | ${VERDICTS[$i]} | ${NOTES[$i]} |"
  done
} > "${REPORT}"

step "Report written to ${REPORT}"
for v in "${VERDICTS[@]}"; do
  [ "${v}" = "PASS" ] || { color_red "SCENARIO FAILED"; exit 1; }
done
color_green "SCENARIO PASSED"
