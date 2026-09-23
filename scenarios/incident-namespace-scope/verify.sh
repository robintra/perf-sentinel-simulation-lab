#!/usr/bin/env bash
# incident-namespace-scope: the 0.25.0 namespace screen on the incident freeze.
#
# On a fleet where each tenant runs the same service in its own namespace, a
# rollout fires one alert per namespace and records one incident per
# namespace. Before 0.25.0 each of them froze the findings of that service in
# EVERY namespace: the incident's `namespace` was a label, the freeze screened
# by service and window alone, and every tenant's post-mortem read every other
# tenant's findings. 0.25.0 leaves out a finding whose grouping names a
# different `k8s.namespace.name`, and keeps one that names none.
#
# Legs, each closing a hole the screen has to defend:
#
#   A. The daemon runs `grouping_attributes = ["service.namespace",
#      "k8s.namespace.name"]`, the namespace second, where the screen still has
#      to find it. The ring holds the same n+1 on the same service in two
#      namespaces, once with no namespace at all, and once under
#      `service.namespace=commerce` with the namespace behind it. The control
#      asserts the ring keeps them apart before any alert, or the legs below
#      would prove nothing.
#   B. The freeze at reception. One delivery, three alerts on the same service
#      at the same instant: tenant-a, tenant-b, and no namespace. Each tenant's
#      incident holds its own rows and the unlabelled one, never the other
#      tenant's. The second-position row lands in tenant-b alone: a screen that
#      read only the first grouping attribute would leak it into tenant-a. The
#      incident without a namespace freezes by service, all four rows.
#   C. The settle pass screens too. Both tenants get a new anti-pattern right
#      after the delivery, analysed after the reception freeze. After the
#      settle each tenant's record grew by its own row and by nothing of the
#      other's. Both grow, so "tenant-a held no tenant-b row" cannot pass on a
#      settle that never ran.
#   D. `findings=false`. The listing without the frozen findings, what the lab
#      dashboard's Incidents table reads since 0.25.0: no `findings` key,
#      `finding_count` equal to the full record's length, every other field
#      unchanged, by page, by namespace and by id. A malformed `findings` or
#      `offset` answers 401 before 400, the key is judged first.
#   E. The archive holds what the ring held: every record of the tenant-a
#      incident, reception and settle, without a tenant-b row.
#   F. The startup warning. `[daemon.incidents]` enabled without
#      `k8s.namespace.name` among `grouping_attributes` warns and starts, and
#      the config of legs A to E, which has it second, does not warn. Under
#      `["tenant.id"]` the ingest keeps no namespace attribute, so a tenant-b
#      trace lands in a tenant-a incident: a freeze by service, as the warning
#      says.
#
# Local binary, no cluster.

set -uo pipefail
# Job control off: the shell would otherwise print "Terminated" of its own
# every time the daemon is killed, which reads like a failure mid-scenario.
set +m

SCENARIO="incident-namespace-scope"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
# Short on purpose: the daemon's JSON socket lives here and a Unix socket path
# is capped near 104 bytes.
TMP_DIR="/tmp/ins"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
HTTP_PORT="${INS_HTTP_PORT:-14562}"
GRPC_PORT="${INS_GRPC_PORT:-14563}"
# The settle fires at `at_ms + 3 * trace_ttl_ms`, so the TTL sets the length of
# the scenario, as in incident-window-capture.
TTL_MS="${INS_TTL_MS:-2000}"
API_KEY="lab-incident-key"
# The read key must differ from the write key, the daemon refuses them equal.
READ_KEY="lab-read-key-0000"
WARNING="without k8s.namespace.name among"

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
VERSION="$("${PERF_SENTINEL_LOCAL_BIN}" --version | awk '{print $2}')"
ok "perf-sentinel ${VERSION} at ${PERF_SENTINEL_LOCAL_BIN}"

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
rfc3339() {
  python3 -c "
import datetime, sys
ms = int(sys.argv[1])
print(datetime.datetime.fromtimestamp(ms / 1000, datetime.timezone.utc)
      .strftime('%Y-%m-%dT%H:%M:%S.') + f'{ms % 1000:03d}Z')
" "$1"
}

# One trace of 8 sibling SELECTs on the same template, an n+1 over the floor
# of 5, on shop-svc. The `grouping` pairs are what places a trace in a
# namespace here, as the OTLP ingest would have captured them from the
# resource. The daemon keeps the keys of `grouping_attributes` and puts them
# in that order, whatever order they are sent in.
# $1 = table, $2 = trace suffix, $3... = key=value grouping pairs.
cat > "${TMP_DIR}/seed.py" <<'PY'
import json, socket, sys
from datetime import datetime, timezone

sock_path, table, suffix, *pairs = sys.argv[1:]
now = datetime.now(timezone.utc)
ts = now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"
tid = (f"ins{suffix}" + "0" * 29)[:32]
grouping = [dict(zip(("key", "value"), p.split("=", 1))) for p in pairs]
events = []
for i in range(1, 9):
    event = {
        "timestamp": ts, "trace_id": tid, "span_id": f"{suffix}{i:015d}"[:16],
        "service": "shop-svc", "cloud_region": "eu-west-3",
        "type": "sql", "operation": "SELECT",
        "target": f"SELECT * FROM {table} WHERE owner_id = {i}",
        "duration_us": 1500,
        "source": {"endpoint": f"GET /{table}", "method": "ShopService::list"},
    }
    if grouping:
        event["grouping"] = grouping
    events.append(event)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock_path)
s.sendall((json.dumps(events) + "\n").encode())
s.close()
PY

seed() { python3 "${TMP_DIR}/seed.py" "${TMP_DIR}/s" "$@"; }

# Where each frozen or listed row sits. Reads a JSON array of stored findings
# on stdin and prints "total tenant-a tenant-b unlabelled second": the rows
# per k8s.namespace.name wherever it sits in the grouping, the rows with none,
# and the rows where it is not the first attribute.
cat > "${TMP_DIR}/where.py" <<'PY'
import json, sys
rows = json.load(sys.stdin)
counts = {"tenant-a": 0, "tenant-b": 0, "-": 0}
second = 0
for row in rows:
    grouping = row["finding"].get("grouping", [])
    names = [g["value"] for g in grouping if g["key"] == "k8s.namespace.name"]
    counts[names[0] if names else "-"] = counts.get(names[0] if names else "-", 0) + 1
    if grouping and grouping[0]["key"] != "k8s.namespace.name" and names:
        second += 1
print(len(rows), counts["tenant-a"], counts["tenant-b"], counts["-"], second)
PY

# The frozen rows of the incident carrying namespace $1 ("-" for none) in the
# listing on stdin, as where.py reads them.
incident_rows() {
  python3 -c "
import json, sys
ns = None if sys.argv[1] == '-' else sys.argv[1]
print(json.dumps(next(i['findings'] for i in json.load(sys.stdin) if i.get('namespace') == ns)))
" "$1" | python3 "${TMP_DIR}/where.py"
}

write_config() {  # $1 = extra [detection] line ("")
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
archive_path = "${TMP_DIR}/incidents.ndjson"

[detection]
n_plus_one_min_occurrences = 5
$1
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

api() {  # $1 = method, $2 = path, $3 = body (""), $4 = key ("")
  local args=(-s -o "${TMP_DIR}/body" -w '%{http_code}' -X "$1")
  [ -n "${3:-}" ] && args+=(-H "content-type: application/json" -d "$3")
  [ -n "${4:-}" ] && args+=(-H "X-API-Key: $4")
  curl "${args[@]}" "http://127.0.0.1:${HTTP_PORT}$2"
}

# One Alertmanager envelope, one firing oom_kill alert on shop-svc per
# namespace argument, "-" for an alert without the label. $1 = startsAt.
alert_body() {
  python3 -c "
import json, sys
starts, *namespaces = sys.argv[1:]
alerts = []
for ns in namespaces:
    labels = {'service': 'shop-svc', 'perf_sentinel_kind': 'oom_kill'}
    if ns != '-':
        labels['namespace'] = ns
    alerts.append({'status': 'firing', 'labels': labels,
                   'annotations': {'summary': 'rollout OOM'},
                   'startsAt': starts, 'endsAt': '0001-01-01T00:00:00Z'})
print(json.dumps({'version': '4', 'alerts': alerts}))
" "$@"
}

jqp() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

# === Startup ===
step "1. Daemon up, k8s.namespace.name second in grouping_attributes"
write_config 'grouping_attributes = ["service.namespace", "k8s.namespace.name"]'
start_daemon "d.log" || die "daemon did not start: $(tail -5 "${TMP_DIR}/d.log")"
ok "daemon up on grouping_attributes = [service.namespace, k8s.namespace.name]"

# === Leg A: four rows the ring keeps apart ===
step "A. The same n+1 in two namespaces, in none, and under service.namespace"
seed orders a k8s.namespace.name=tenant-a
seed orders b k8s.namespace.name=tenant-b
seed orders n
seed orders s service.namespace=commerce k8s.namespace.name=tenant-b

RING="0 0 0 0 0"
for _ in $(seq 1 40); do
  RING="$(curl -s "http://127.0.0.1:${HTTP_PORT}/api/findings?service=shop-svc" | python3 "${TMP_DIR}/where.py")"
  read -r R_TOTAL R_A R_B R_NONE R_SECOND <<< "${RING}"
  [ "${R_A}" -ge 1 ] && [ "${R_B}" -ge 2 ] && [ "${R_NONE}" -ge 1 ] && [ "${R_SECOND}" -ge 1 ] && break
  sleep 0.5
done
read -r R_TOTAL R_A R_B R_NONE R_SECOND <<< "${RING}"
if [ "${R_A}" -ge 1 ] && [ "${R_B}" -ge 2 ] && [ "${R_NONE}" -ge 1 ] && [ "${R_SECOND}" -ge 1 ]; then
  ok "${R_TOTAL} rows: tenant-a ${R_A}, tenant-b ${R_B} (${R_SECOND} behind service.namespace), unlabelled ${R_NONE}"
  record "the ring keeps the namespaces apart" PASS "tenant-a ${R_A}, tenant-b ${R_B}, unlabelled ${R_NONE}, second position ${R_SECOND}"
else
  fail "ring rows (total a b none second): ${RING}"
  record "the ring keeps the namespaces apart" FAIL "${RING}"
  die "the seeds did not land as four separate rows, the legs below would prove nothing"
fi

# === Leg B: the freeze at reception ===
step "B. One delivery, three alerts: each tenant freezes its own namespace"
AT_MS="$(now_ms)"
STARTS="$(rfc3339 "${AT_MS}")"
CODE="$(api POST /api/incidents "$(alert_body "${STARTS}" tenant-a tenant-b -)" "${API_KEY}")"
INTAKE="$(cat "${TMP_DIR}/body")"
# Seeded right away: analysed one TTL from now, after the reception freeze and
# inside the window that closes at +2 TTL, so only the settle can catch them.
seed invoices c k8s.namespace.name=tenant-b
seed carts d k8s.namespace.name=tenant-a

if [ "${CODE}" = "200" ] && [ "$(echo "${INTAKE}" | jqp "d['recorded']")" = "3" ]; then
  ok "delivery accepted, recorded=3: the namespace is part of the id"
  record "one incident per namespace" PASS "recorded=3 on one service, one instant"
else
  fail "HTTP ${CODE}, body ${INTAKE}"
  record "one incident per namespace" FAIL "HTTP ${CODE}, ${INTAKE}"
fi

api GET /api/incidents "" "${API_KEY}" >/dev/null
cp "${TMP_DIR}/body" "${TMP_DIR}/reception.json"
read -r A_TOTAL A_A A_B A_NONE A_SECOND <<< "$(incident_rows tenant-a < "${TMP_DIR}/reception.json")"
read -r B_TOTAL B_A B_B B_NONE B_SECOND <<< "$(incident_rows tenant-b < "${TMP_DIR}/reception.json")"
read -r N_TOTAL N_A N_B N_NONE N_SECOND <<< "$(incident_rows - < "${TMP_DIR}/reception.json")"
TENANT_A_ID="$(jqp "next(i['id'] for i in d if i.get('namespace') == 'tenant-a')" < "${TMP_DIR}/reception.json")"

if [ "${A_A}" -ge 1 ] && [ "${A_B}" = "0" ] && [ "${B_B}" -ge 1 ] && [ "${B_A}" = "0" ]; then
  ok "tenant-a froze ${A_A} tenant-a row(s) and no tenant-b one, tenant-b the mirror (${B_B}, 0)"
  record "the other namespace is left out" PASS "tenant-a: a=${A_A} b=0, tenant-b: b=${B_B} a=0"
else
  fail "tenant-a incident: a=${A_A} b=${A_B}, tenant-b incident: a=${B_A} b=${B_B}"
  record "the other namespace is left out" FAIL "tenant-a a=${A_A} b=${A_B}, tenant-b a=${B_A} b=${B_B}"
fi

if [ "${A_NONE}" -ge 1 ] && [ "${B_NONE}" -ge 1 ]; then
  ok "the unlabelled row is in both tenants' records: nothing places it elsewhere"
  record "an unlabelled finding is kept" PASS "tenant-a ${A_NONE}, tenant-b ${B_NONE}"
else
  fail "unlabelled rows: tenant-a ${A_NONE}, tenant-b ${B_NONE}"
  record "an unlabelled finding is kept" FAIL "tenant-a ${A_NONE}, tenant-b ${B_NONE}"
fi

if [ "${B_SECOND}" -ge 1 ] && [ "${A_SECOND}" = "0" ]; then
  ok "the row with tenant-b behind service.namespace went to tenant-b alone"
  record "the attribute is read in any position" PASS "tenant-b ${B_SECOND}, tenant-a 0"
else
  fail "second-position rows: tenant-b ${B_SECOND}, tenant-a ${A_SECOND} (a first-attribute screen leaks it)"
  record "the attribute is read in any position" FAIL "tenant-b ${B_SECOND}, tenant-a ${A_SECOND}"
fi

if [ "${N_A}" -ge 1 ] && [ "${N_B}" -ge 2 ] && [ "${N_NONE}" -ge 1 ]; then
  ok "the alert without a namespace froze by service: ${N_TOTAL} rows across both tenants"
  record "no namespace freezes by service" PASS "a=${N_A} b=${N_B} unlabelled=${N_NONE}"
else
  fail "no-namespace incident: a=${N_A} b=${N_B} unlabelled=${N_NONE}"
  record "no namespace freezes by service" FAIL "a=${N_A} b=${N_B} unlabelled=${N_NONE}"
fi

# === Leg C: the settle pass screens too ===
step "C. The settle merges each tenant's new row, and nothing of the other's"
SLEEP_S="$(python3 -c "
import time
due = (${AT_MS} + 3 * ${TTL_MS} + 1500) / 1000
print(max(0.0, due - time.time()))
")"
sleep "${SLEEP_S}"

api GET /api/incidents "" "${API_KEY}" >/dev/null
cp "${TMP_DIR}/body" "${TMP_DIR}/settled.json"
read -r SA_TOTAL SA_A SA_B _ _ <<< "$(incident_rows tenant-a < "${TMP_DIR}/settled.json")"
read -r SB_TOTAL SB_A SB_B _ _ <<< "$(incident_rows tenant-b < "${TMP_DIR}/settled.json")"

if [ "${SA_A}" -gt "${A_A}" ] && [ "${SB_B}" -gt "${B_B}" ] && [ "${SA_B}" = "0" ] && [ "${SB_A}" = "0" ]; then
  ok "tenant-a ${A_TOTAL} -> ${SA_TOTAL} rows on its own row, tenant-b ${B_TOTAL} -> ${SB_TOTAL} on its own"
  ok "and neither record picked up the other tenant's settle row"
  record "the settle screens too" PASS "tenant-a a ${A_A}->${SA_A} b=0, tenant-b b ${B_B}->${SB_B} a=0"
else
  fail "tenant-a a ${A_A}->${SA_A} b=${SA_B}, tenant-b b ${B_B}->${SB_B} a=${SB_A}"
  fail "both must grow (the settle ran) and neither may hold the other's row"
  record "the settle screens too" FAIL "tenant-a a ${A_A}->${SA_A} b=${SA_B}, tenant-b b ${B_B}->${SB_B} a=${SB_A}"
fi

# === Leg D: findings=false ===
step "D. findings=false: the count in place of the findings, everything else unchanged"
api GET /api/incidents "" "${READ_KEY}" >/dev/null
cp "${TMP_DIR}/body" "${TMP_DIR}/full.json"
cat > "${TMP_DIR}/summary.py" <<'PY'
import json, sys
full = {i["id"]: i for i in json.load(open(sys.argv[1]))}
summaries = json.load(sys.stdin)
bad = []
for s in summaries:
    f = dict(full[s["id"]])
    expected = {k: v for k, v in f.items() if k != "findings"}
    expected["finding_count"] = len(f["findings"])
    if "findings" in s or s != expected:
        bad.append(s["id"][:8])
print(len(summaries), ",".join(bad) or "none")
PY
summary_check() { python3 "${TMP_DIR}/summary.py" "${TMP_DIR}/full.json" < "${TMP_DIR}/body"; }

api GET "/api/incidents?findings=false" "" "${READ_KEY}" >/dev/null
read -r PAGE_N PAGE_BAD <<< "$(summary_check)"
api GET "/api/incidents?namespace=tenant-a&findings=false" "" "${READ_KEY}" >/dev/null
read -r NS_N NS_BAD <<< "$(summary_check)"
NS_LABEL="$(jqp "d[0].get('namespace') if d else 'absent'" < "${TMP_DIR}/body")"
api GET "/api/incidents?id=${TENANT_A_ID}&findings=false" "" "${READ_KEY}" >/dev/null
read -r ID_N ID_BAD <<< "$(summary_check)"

if [ "${PAGE_N}" = "3" ] && [ "${PAGE_BAD}" = "none" ] \
   && [ "${NS_N}" = "1" ] && [ "${NS_BAD}" = "none" ] && [ "${NS_LABEL}" = "tenant-a" ] \
   && [ "${ID_N}" = "1" ] && [ "${ID_BAD}" = "none" ]; then
  ok "3 summaries by page, 1 by namespace, 1 by id: no findings key, finding_count = the"
  ok "full record's length, every other field equal"
  record "findings=false summarises" PASS "page 3, namespace 1, id 1, all equal to the full record less its findings"
else
  fail "page ${PAGE_N} (mismatch ${PAGE_BAD}), namespace ${NS_N} ${NS_LABEL} (${NS_BAD}), id ${ID_N} (${ID_BAD})"
  record "findings=false summarises" FAIL "page ${PAGE_N}/${PAGE_BAD}, ns ${NS_N}/${NS_BAD}, id ${ID_N}/${ID_BAD}"
fi

# The key before the parameters: a caller without it learns nothing from a
# 400. Before 0.25.0 a malformed offset answered 400 ahead of the key.
F_BARE="$(api GET "/api/incidents?findings=maybe" "" "")"
F_KEYED="$(api GET "/api/incidents?findings=maybe" "" "${READ_KEY}")"
O_BARE="$(api GET "/api/incidents?offset=many" "" "")"
O_KEYED="$(api GET "/api/incidents?offset=many" "" "${READ_KEY}")"
if [ "${F_BARE}${F_KEYED}${O_BARE}${O_KEYED}" = "401400401400" ]; then
  ok "findings=maybe and offset=many: 401 without the key, 400 with it"
  record "the key is judged first" PASS "findings 401/400, offset 401/400"
else
  fail "findings=maybe ${F_BARE}/${F_KEYED}, offset=many ${O_BARE}/${O_KEYED} (expected 401/400 both)"
  record "the key is judged first" FAIL "findings ${F_BARE}/${F_KEYED}, offset ${O_BARE}/${O_KEYED}"
fi

# === Leg E: the archive ===
step "E. Every archived record of the tenant-a incident is screened"
stop_daemon
ARCHIVE_READ="$(python3 -c "
import json, sys
lines = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
mine = [r for r in lines if r['id'] == sys.argv[2]]
leaked = sum(1 for r in mine for f in r['findings']
             for g in f['finding'].get('grouping', [])
             if g['key'] == 'k8s.namespace.name' and g['value'] != 'tenant-a')
print(len(mine), max((len(r['findings']) for r in mine), default=0), leaked)
" "${TMP_DIR}/incidents.ndjson" "${TENANT_A_ID}")"
read -r E_LINES E_MAX E_LEAKED <<< "${ARCHIVE_READ}"
if [ "${E_LINES}" -ge 2 ] && [ "${E_MAX}" = "${SA_TOTAL}" ] && [ "${E_LEAKED}" = "0" ]; then
  ok "${E_LINES} records for tenant-a (reception and settle), up to ${E_MAX} rows, none from another namespace"
  record "the archive is screened" PASS "${E_LINES} records, max ${E_MAX} rows, 0 foreign"
else
  fail "records=${E_LINES}, max rows=${E_MAX} (ring ${SA_TOTAL}), foreign rows=${E_LEAKED}"
  record "the archive is screened" FAIL "${E_LINES}/${E_MAX}/${E_LEAKED}"
fi

# === Leg F: the startup warning ===
step "F. Without k8s.namespace.name among grouping_attributes: a warning, and a freeze by service"
if grep -q "${WARNING}" "${TMP_DIR}/d.log"; then
  DEFAULT_WARNED=yes
else
  DEFAULT_WARNED=no
fi

rm -f "${TMP_DIR}/incidents.ndjson"
write_config 'grouping_attributes = ["tenant.id"]'
start_daemon "d-tenant.log" || die "daemon on tenant.id did not start: $(tail -5 "${TMP_DIR}/d-tenant.log")"
if grep -q "${WARNING}" "${TMP_DIR}/d-tenant.log" \
   && [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HTTP_PORT}/api/status")" = "200" ] \
   && [ "${DEFAULT_WARNED}" = "no" ]; then
  ok "tenant.id alone: the daemon warns and serves, the namespace second did not warn"
  record "the startup warning" PASS "warned on tenant.id, silent with the namespace second"
else
  fail "warned on tenant.id: $(grep -c "${WARNING}" "${TMP_DIR}/d-tenant.log"), with the namespace second: ${DEFAULT_WARNED}"
  record "the startup warning" FAIL "tenant.id log $(grep -c "${WARNING}" "${TMP_DIR}/d-tenant.log"), namespace second ${DEFAULT_WARNED}"
fi

# A tenant-b trace. Under that config the ingest keeps tenant.id alone, so the
# finding carries no namespace and nothing places it outside tenant-a.
seed orders t tenant.id=acme k8s.namespace.name=tenant-b
for _ in $(seq 1 40); do
  [ "$(curl -s "http://127.0.0.1:${HTTP_PORT}/api/findings?service=shop-svc" | jqp 'len(d)')" -ge 1 ] && break
  sleep 0.5
done
api POST /api/incidents "$(alert_body "$(rfc3339 "$(now_ms)")" tenant-a)" "${API_KEY}" >/dev/null
api GET "/api/incidents?namespace=tenant-a" "" "${API_KEY}" >/dev/null
T_FROZEN="$(jqp "len(d[0]['findings']) if d else 'absent'" < "${TMP_DIR}/body")"
if [ "${T_FROZEN}" != "absent" ] && [ "${T_FROZEN}" -ge 1 ]; then
  ok "an alert on tenant-a froze the tenant-b trace: by service alone, as the warning says"
  record "grouped elsewhere, freezes by service" PASS "${T_FROZEN} row(s) frozen"
else
  fail "frozen under tenant.id: ${T_FROZEN}"
  record "grouped elsewhere, freezes by service" FAIL "${T_FROZEN}"
fi
stop_daemon

# === Report ===
{
  echo "# Scenario: ${SCENARIO}"
  echo
  echo "Binary: \`${PERF_SENTINEL_LOCAL_BIN}\` (${VERSION})"
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
