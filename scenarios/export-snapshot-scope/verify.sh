#!/usr/bin/env bash
# export-snapshot-scope: what one `/api/export/report` snapshot covers, and
# what a client does when it cannot read one (0.13.1).
#
# The daemon Report an operator pulls is a SLICE, not the store: findings are
# capped at `[daemon] max_export_findings` (now configurable, also
# `watch --max-export-findings`), and the green figures describe the latest
# analyzed batch. Three things follow, and each is a gate here:
#
#   A. The cap is real and reaches its clients. It is exposed on /api/config,
#      it truncates the exported findings, and at 0 it empties them. That last
#      one is a trap rather than a corner case: the exported `quality_gate`
#      counts the exported slice, so at 0 the count rules read actual=0 and
#      pass over a daemon that detected critical findings. A CI job reading
#      those rules merges on them. The A/B here is the same traces through the
#      same daemon, differing only by the cap. What does NOT follow is the
#      whole verdict flipping: `io_waste_ratio_max` comes from the green
#      summary, which no cap empties, so it can still fail the gate. CHANGELOG
#      and docs/CONFIGURATION.md claim the verdict "then passes whatever the
#      daemon detected"; docs/QUERY-API.md describes the real split. This
#      scenario pins the split, not the claim.
#   B. `snapshot_scope` in `warning_details` says so in the payload: one entry
#      always (green figures = one batch), a second one only when the store
#      holds more than the export ships. The cold-start envelope carries
#      NEITHER — deliberate, and pinned here because nothing upstream pins it.
#   C. A snapshot too large for the 8 MiB the query clients read is reported as
#      such instead of being flattened into an unreachable daemon. `query
#      monitor` names the reason beside its [STALE] marker. (`query inspect`
#      still flattens it to None: known and accepted upstream, asserted here as
#      the documented gap rather than left to drift silently.)
#   T. Startup advisory: the two knobs project a body past the read limit
#      TOGETHER. `max_retained_traces` alone can no longer trigger it at any
#      value, because the span-tree term is clamped to the budget
#      `traces_store::snapshot_for` already applies.
#
# Self-contained: local release binary, python3, jq. No cluster, no Docker.
set -euo pipefail

SCENARIO="export-snapshot-scope"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
mkdir -p "${TMP_DIR}"
# A stale PASS report from a previous run must not survive a failing re-run.
rm -f "${REPORT}"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
DAEMON_HTTP_PORT="${DAEMON_HTTP_PORT:-14626}"
DAEMON_GRPC_PORT="${DAEMON_GRPC_PORT:-14627}"
STUB_PORT="${STUB_PORT:-14628}"
DAEMON_URL="http://127.0.0.1:${DAEMON_HTTP_PORT}"
# AF_UNIX paths are capped around 104 chars, so /tmp rather than TMP_DIR.
SOCK="${SOCK:-/tmp/ps-ess-$$.sock}"
# Body the query clients refuse to read past, mirroring http_client::MAX_BODY_BYTES.
OVERSIZE_BYTES=$((9 * 1024 * 1024))

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

declare -a NAMES=() VERDICTS=() NOTES=()
record() { NAMES+=("$1"); VERDICTS+=("$2"); NOTES+=("$3"); }

DAEMON_PID=""
STUB_PID=""
cleanup() {
  [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true
  [ -n "${STUB_PID}" ] && kill "${STUB_PID}" 2>/dev/null || true
  rm -f "${SOCK}" 2>/dev/null || true
}
trap cleanup EXIT

step "0. Pre-flight"
[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release --workspace first)"
command -v jq >/dev/null      || die "jq not on PATH"
command -v python3 >/dev/null || die "python3 not on PATH"
ok "binary $(basename "${PERF_SENTINEL_LOCAL_BIN}") $("${PERF_SENTINEL_LOCAL_BIN}" --version | awk '{print $2}')"

cat > "${TMP_DIR}/daemon.toml" <<EOF
[daemon]
listen_address = "127.0.0.1"
listen_port_http = ${DAEMON_HTTP_PORT}
listen_port_grpc = ${DAEMON_GRPC_PORT}
json_socket = "${SOCK}"
api_enabled = true
trace_ttl_ms = 1000

[daemon.ack]
enabled = false

# A single critical N+1 must flip the exported gate, so the A3 A/B reads the
# cap and nothing else.
[thresholds]
n_plus_one_sql_critical_max = 0

[detection]
n_plus_one_min_occurrences = 5
EOF

start_daemon() {  # $1 = --max-export-findings value, "" for the config default
  [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true
  DAEMON_PID=""
  # Require the port to fall silent first: a leftover daemon from an aborted
  # run would otherwise answer readiness and the legs below would grade it.
  for _ in $(seq 1 20); do
    curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 || break
    sleep 0.5
  done
  curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 \
    && die "something already serves ${DAEMON_URL} - leftover daemon from a previous run?"
  rm -f "${SOCK}"
  if [ -n "$1" ]; then
    "${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/daemon.toml" \
      --max-export-findings "$1" > "${TMP_DIR}/daemon.log" 2>&1 &
  else
    "${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/daemon.toml" \
      > "${TMP_DIR}/daemon.log" 2>&1 &
  fi
  DAEMON_PID=$!
  for _ in $(seq 1 40); do
    curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 && break
    sleep 0.5
  done
  kill -0 "${DAEMON_PID}" 2>/dev/null || die "spawned daemon died: $(tail -3 "${TMP_DIR}/daemon.log")"
  curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 \
    || die "daemon not ready: $(tail -3 "${TMP_DIR}/daemon.log")"
}

# Three distinct N+1 SQL traces: distinct endpoints and templates, so they
# group into three signatures rather than one aggregated finding.
inject_three_findings() {
  python3 - "${SOCK}" <<'PY'
import json, socket, sys

sock = sys.argv[1]
routes = [("orders", "/api/orders"), ("users", "/api/users"), ("carts", "/api/carts")]
events = []
for t, (table, endpoint) in enumerate(routes):
    tid = "tess%d" % t
    for i in range(1, 13):
        events.append({
            "timestamp": "2025-06-07T12:00:00.%03dZ" % (i * 4),
            "trace_id": tid, "span_id": "s%d%05d" % (t, i), "parent_span_id": "s%d00000" % t,
            "service": "export-scope-svc", "cloud_region": "eu-west-3", "type": "sql",
            "operation": "SELECT",
            "target": "SELECT * FROM %s WHERE id = %d" % (table, i),
            "duration_us": 2000,
            "source": {"endpoint": endpoint, "method": "h"},
        })
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock)
s.sendall((json.dumps(events) + "\n").encode())
s.close()
PY
  # Poll rather than sleep: the trace finalizes at trace_ttl_ms and the async
  # analysis worker publishes some time after that.
  for _ in $(seq 1 30); do
    [ "$(curl -fsS "${DAEMON_URL}/api/status" | jq -r '.stored_findings')" -ge 3 ] 2>/dev/null && return 0
    sleep 1
  done
  die "only $(curl -fsS "${DAEMON_URL}/api/status" | jq -r '.stored_findings') finding(s) stored after injection, expected >= 3"
}

scope_entries() {  # count of snapshot_scope entries in $1 (a report JSON file)
  jq '[.warning_details[]? | select(.kind == "snapshot_scope")] | length' "$1"
}

# =============================================================================
step "B3. cold-start envelope carries no snapshot_scope"
start_daemon ""
curl -fsS "${DAEMON_URL}/api/export/report" > "${TMP_DIR}/cold.json"
COLD_EVENTS="$(jq -r '.analysis.events_processed' "${TMP_DIR}/cold.json")"
COLD_KINDS="$(jq -r '[.warning_details[]?.kind] | join(",")' "${TMP_DIR}/cold.json")"
[ "${COLD_EVENTS}" = "0" ] || die "expected a cold daemon, events_processed=${COLD_EVENTS}"
[ "$(scope_entries "${TMP_DIR}/cold.json")" = "0" ] \
  || die "cold envelope carries snapshot_scope (kinds: ${COLD_KINDS}), it describes nothing yet"
record "B3-cold" "PASS" "cold envelope: kinds=[${COLD_KINDS}], no snapshot_scope"
ok "cold envelope carries no snapshot_scope (kinds: ${COLD_KINDS})"

# =============================================================================
step "B1 + A3-baseline. default cap: one scope entry, gate sees the findings"
inject_three_findings
curl -fsS "${DAEMON_URL}/api/export/report" > "${TMP_DIR}/wide.json"
WIDE_STORED="$(curl -fsS "${DAEMON_URL}/api/status" | jq -r '.stored_findings')"
WIDE_EXPORTED="$(jq '.findings | length' "${TMP_DIR}/wide.json")"
WIDE_SCOPE="$(scope_entries "${TMP_DIR}/wide.json")"
WIDE_GATE="$(jq -r '.quality_gate.passed' "${TMP_DIR}/wide.json")"
[ "${WIDE_EXPORTED}" = "${WIDE_STORED}" ] \
  || die "default cap 1000 truncated ${WIDE_STORED} findings to ${WIDE_EXPORTED}"
[ "${WIDE_SCOPE}" = "1" ] \
  || die "expected exactly 1 snapshot_scope entry when the store fits, got ${WIDE_SCOPE}"
jq -e '[.warning_details[] | select(.kind == "snapshot_scope")][0].message
       | test("Green figures.*describe the latest analyzed batch")' \
  "${TMP_DIR}/wide.json" >/dev/null || die "the lone scope entry is not the green-figures one"
[ "${WIDE_GATE}" = "false" ] \
  || die "expected a failing gate on ${WIDE_EXPORTED} critical findings, got passed=${WIDE_GATE}"
record "B1-batch-entry" "PASS" "store fits (${WIDE_EXPORTED}/${WIDE_STORED}): the green-figures entry alone"
record "A3-baseline" "PASS" "same traces, cap 1000: quality_gate.passed=false"
ok "${WIDE_EXPORTED} findings exported, 1 scope entry, gate passed=false"

# =============================================================================
step "A1 + A2 + B2. cap 2: exposed on /api/config, truncates, and says so"
start_daemon 2
inject_three_findings
CFG_CAP="$(curl -fsS "${DAEMON_URL}/api/config" | jq -r '.max_export_findings')"
CFG_TRACES="$(curl -fsS "${DAEMON_URL}/api/config" | jq -r '.max_retained_traces')"
[ "${CFG_CAP}" = "2" ] \
  || die "/api/config reports max_export_findings=${CFG_CAP}, the CLI override (2) never reached it"
[ "${CFG_TRACES}" != "null" ] || die "/api/config does not expose max_retained_traces"
curl -fsS "${DAEMON_URL}/api/export/report" > "${TMP_DIR}/capped.json"
CAP_STORED="$(curl -fsS "${DAEMON_URL}/api/status" | jq -r '.stored_findings')"
CAP_EXPORTED="$(jq '.findings | length' "${TMP_DIR}/capped.json")"
[ "${CAP_EXPORTED}" = "2" ] || die "cap 2 exported ${CAP_EXPORTED} findings"
[ "${CAP_STORED}" -gt "${CAP_EXPORTED}" ] \
  || die "store (${CAP_STORED}) did not outgrow the export (${CAP_EXPORTED}), the leg proves nothing"
[ "$(scope_entries "${TMP_DIR}/capped.json")" = "2" ] \
  || die "expected 2 snapshot_scope entries when the store outgrows the export, got $(scope_entries "${TMP_DIR}/capped.json")"
# The truncation entry must carry BOTH counts and warn about the gate: a reader
# who sees only "capped" cannot tell how much of the store is missing.
jq -e --argjson e "${CAP_EXPORTED}" --argjson r "${CAP_STORED}" \
  '[.warning_details[] | select(.kind == "snapshot_scope")][0].message
   | test("capped at \($e) of \($r) retained") and test("quality gate below counts only these")' \
  "${TMP_DIR}/capped.json" >/dev/null \
  || die "truncation entry does not name both counts and the gate: $(jq -r '[.warning_details[] | select(.kind=="snapshot_scope")][0].message' "${TMP_DIR}/capped.json")"
record "A1-config" "PASS" "/api/config: max_export_findings=2 (CLI override), max_retained_traces=${CFG_TRACES}"
record "A2-truncates" "PASS" "cap 2 over a store of ${CAP_STORED}: 2 exported"
record "B2-truncation-entry" "PASS" "2 scope entries, the first naming 2 of ${CAP_STORED} and the gate"
ok "cap 2 exposed, enforced, and disclosed (store ${CAP_STORED})"

# =============================================================================
step "A3. cap 0: envelope only, and count rules that no longer see the findings"
start_daemon 0
inject_three_findings
curl -fsS "${DAEMON_URL}/api/export/report" > "${TMP_DIR}/zero.json"
ZERO_STORED="$(curl -fsS "${DAEMON_URL}/api/status" | jq -r '.stored_findings')"
ZERO_EXPORTED="$(jq '.findings | length' "${TMP_DIR}/zero.json")"
[ "${ZERO_EXPORTED}" = "0" ] || die "cap 0 exported ${ZERO_EXPORTED} findings, expected the envelope alone"
[ "${ZERO_STORED}" -ge 3 ] || die "store holds ${ZERO_STORED} findings, the A/B against the baseline is void"
# THE trap, measured precisely. Same traces, same thresholds, same daemon
# build as A3-baseline, where n_plus_one_sql_critical_max read actual=3 and
# failed: at cap 0 it reads actual=0 and PASSES. A CI probe reading that rule
# sees a clean daemon.
jq -e '.quality_gate.rules[]
       | select(.rule == "n_plus_one_sql_critical_max")
       | select(.actual == 0 and .passed == true)' "${TMP_DIR}/zero.json" >/dev/null \
  || die "cap 0 did not empty the count rule: $(jq -c '.quality_gate.rules[] | select(.rule=="n_plus_one_sql_critical_max")' "${TMP_DIR}/zero.json")"
# But the verdict is NOT guaranteed to flip, and asserting that it does would
# pin a claim the product contradicts elsewhere. CHANGELOG and
# docs/CONFIGURATION.md say the verdict "then passes whatever the daemon
# detected"; docs/QUERY-API.md says the gate "counts finding-based rules on the
# exported slice AND reads io_waste_ratio from that batch". The second one is
# what runs: io_waste_ratio_max comes from the green summary, which no cap
# empties, so it still fails here on the same traces. Both facts are the leg.
jq -e '.quality_gate.rules[]
       | select(.rule == "io_waste_ratio_max")
       | select(.actual > 0)' "${TMP_DIR}/zero.json" >/dev/null \
  || die "io_waste_ratio_max reads 0 at cap 0; it is supposed to come from the batch, not the exported slice"
ZERO_GATE="$(jq -r '.quality_gate.passed' "${TMP_DIR}/zero.json")"
ZERO_RATIO="$(jq -r '.quality_gate.rules[] | select(.rule=="io_waste_ratio_max") | .actual' "${TMP_DIR}/zero.json")"
[ "$(scope_entries "${TMP_DIR}/zero.json")" = "2" ] \
  || die "cap 0 hides ${ZERO_STORED} findings without a truncation entry to say so"
record "A3-zero-cap-counts" "PASS" "cap 0: 0 exported of ${ZERO_STORED}, n_plus_one_sql_critical_max actual 3 -> 0 and passes"
record "A3-ratio-survives" "PASS" "io_waste_ratio_max still reads ${ZERO_RATIO} from the batch (gate passed=${ZERO_GATE}, not the unconditional pass CHANGELOG claims)"
ok "cap 0 blinds the count rules over ${ZERO_STORED} hidden findings; io_waste_ratio_max survives it"

# =============================================================================
step "C1. an oversized snapshot is named, not flattened into an unreachable daemon"
# The client refuses past 8 MiB before parsing, so the stub body only has to be
# big — the small-body control below is served by the real daemon.
cat > "${TMP_DIR}/stub.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port, size = int(sys.argv[1]), int(sys.argv[2])
head, tail = '{"warnings":["', '"],"warning_details":[],"findings":[]}'
BODY = (head + "x" * (size - len(head) - len(tail)) + tail).encode()


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/export/report":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(BODY)))
            self.end_headers()
            try:
                self.wfile.write(BODY)
            except (BrokenPipeError, ConnectionResetError):
                pass  # the client cutting the read at its cap is the point
        else:
            self.send_error(404)

    def log_message(self, *a):
        pass


HTTPServer(("127.0.0.1", port), H).serve_forever()
PY

# `script(1)` needs a tty on its own stdin, which CI does not have; openpty
# does not. Without a pty the TUI renders nothing at all.
cat > "${TMP_DIR}/pty_run.py" <<'PY'
import fcntl, os, pty, select, signal, struct, subprocess, sys, termios, time

secs, cols, rows = float(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
p = subprocess.Popen(sys.argv[4:], stdin=slave, stdout=slave, stderr=slave, close_fds=True)
os.close(slave)
out, deadline = bytearray(), time.time() + secs
while True:
    left = deadline - time.time()
    if left <= 0:
        break
    # select, not a bare read: a TUI that stops redrawing would block past
    # the deadline and hang the scenario.
    if not select.select([master], [], [], min(left, 0.5))[0]:
        continue
    try:
        chunk = os.read(master, 65536)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
p.send_signal(signal.SIGTERM)
try:
    p.wait(timeout=5)
except subprocess.TimeoutExpired:
    p.kill()
os.write(1, bytes(out))
PY

monitor_header() {  # $1 = daemon URL -> the header line, ANSI stripped
  python3 "${TMP_DIR}/pty_run.py" 7 200 50 \
    "${PERF_SENTINEL_LOCAL_BIN}" query --daemon "$1" monitor --refresh 1 2>/dev/null \
    | LC_ALL=C tr -d '\000' | sed $'s/\033\[[0-9;?]*[a-zA-Z]//g;s/\033[()][B0]//g'
}

start_stub() {
  python3 "${TMP_DIR}/stub.py" "${STUB_PORT}" "${OVERSIZE_BYTES}" >/dev/null 2>&1 &
  STUB_PID=$!
  for _ in $(seq 1 20); do
    # Range request: readiness without pulling the 9 MiB body.
    curl -fsS -o /dev/null -r 0-16 "http://127.0.0.1:${STUB_PORT}/api/export/report" 2>/dev/null && return 0
    sleep 0.5
  done
  die "the oversize stub never came up on ${STUB_PORT}"
}
stop_stub() {
  [ -n "${STUB_PID}" ] || return 0
  kill "${STUB_PID}" 2>/dev/null || true
  # Reap it here, otherwise bash prints its own "Terminated" job notice.
  wait "${STUB_PID}" 2>/dev/null || true
  STUB_PID=""
}

start_stub
monitor_header "http://127.0.0.1:${STUB_PORT}" > "${TMP_DIR}/monitor-oversize.txt"
grep -q 'STALE' "${TMP_DIR}/monitor-oversize.txt" \
  || die "monitor did not mark an unreadable snapshot as stale"
grep -q 'over the 8 MB read limit' "${TMP_DIR}/monitor-oversize.txt" \
  || die "monitor reports [STALE] without naming the read limit: $(grep -o 'STALE.\{0,90\}' "${TMP_DIR}/monitor-oversize.txt" | tail -1)"
# The reason must name the knob to turn, not just the symptom: cut before it,
# it is no better than the bare marker it replaces.
grep -q 'lower max_export_findings' "${TMP_DIR}/monitor-oversize.txt" \
  || die "the reason survives truncation without naming a fix"
stop_stub

# Control: the real daemon, whose body is well under the limit, is not stale.
monitor_header "${DAEMON_URL}" > "${TMP_DIR}/monitor-ok.txt"
grep -q 'read limit' "${TMP_DIR}/monitor-ok.txt" \
  && die "a normal-sized snapshot is reported as oversized"
record "C1-oversize-named" "PASS" "[STALE] + 'over the 8 MB read limit: lower max_export_findings ...'"
record "C1-control" "PASS" "the live daemon's normal body is not reported as oversized"
ok "monitor names the oversized body and leaves the normal one alone"

# `query inspect` was not fixed: it still flattens the oversize read into an
# empty view. Pinned as the known gap so a later fix shows up here as a FAIL
# to re-read rather than passing unnoticed.
start_stub
python3 "${TMP_DIR}/pty_run.py" 6 200 50 \
  "${PERF_SENTINEL_LOCAL_BIN}" query --daemon "http://127.0.0.1:${STUB_PORT}" inspect 2>/dev/null \
  | LC_ALL=C tr -d '\000' | sed $'s/\033\[[0-9;?]*[a-zA-Z]//g' > "${TMP_DIR}/inspect-oversize.txt"
stop_stub
if grep -q 'read limit' "${TMP_DIR}/inspect-oversize.txt"; then
  record "C2-inspect-gap" "CHANGED" "query inspect now names the read limit — the known gap was closed, update this leg"
  ok "query inspect now names the read limit (upstream gap closed)"
else
  record "C2-inspect-gap" "KNOWN" "query inspect still flattens the oversize read (accepted upstream, not a lab failure)"
  ok "query inspect still flattens the oversize read, as documented"
fi

# =============================================================================
step "T. startup advisory fires on the PAIR, never on retained traces alone"
kill "${DAEMON_PID}" 2>/dev/null || true; DAEMON_PID=""
advisory_log() {  # $1 = max_retained_traces, $2 = --max-export-findings ("" = default)
  local toml="${TMP_DIR}/advisory.toml" log="${TMP_DIR}/advisory.log"
  cat > "${toml}" <<EOF
[daemon]
listen_address = "127.0.0.1"
listen_port_http = ${DAEMON_HTTP_PORT}
listen_port_grpc = ${DAEMON_GRPC_PORT}
max_retained_traces = $1
api_enabled = true

[daemon.ack]
enabled = false
EOF
  if [ -n "$2" ]; then
    "${PERF_SENTINEL_LOCAL_BIN}" watch --config "${toml}" --max-export-findings "$2" > "${log}" 2>&1 &
  else
    "${PERF_SENTINEL_LOCAL_BIN}" watch --config "${toml}" > "${log}" 2>&1 &
  fi
  local pid=$!
  sleep 3
  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
  cat "${log}"
}

# 2000 * 3.5 KB + min(400 * 20 KB, 4 MiB) is around 10 MB, past the 8 MiB limit.
advisory_log 400 2000 > "${TMP_DIR}/advisory-pair.txt"
grep -q 'project a snapshot around' "${TMP_DIR}/advisory-pair.txt" \
  || die "no projection advisory for max_export_findings=2000 + max_retained_traces=400"
grep -q 'max_export_findings = 2000 and max_retained_traces = 400' "${TMP_DIR}/advisory-pair.txt" \
  || die "the advisory does not name both knobs and their values"
# The span-tree term is clamped to the export's own budget (half the body
# limit), so this knob cannot reach the ceiling on its own at any value.
advisory_log 100000 "" > "${TMP_DIR}/advisory-traces-only.txt"
grep -q 'project a snapshot around' "${TMP_DIR}/advisory-traces-only.txt" \
  && die "max_retained_traces=100000 alone still trips the advisory; the clamp regressed"
record "T-pair-warns" "PASS" "the pair (2000 + 400) projects ~10 MB and is named"
record "T-traces-clamped" "PASS" "max_retained_traces=100000 alone is silent (span-tree term clamped)"
ok "the advisory fires on the pair and stays silent on traces alone"

# =============================================================================
step "Summary"
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "What one \`/api/export/report\` snapshot covers (0.13.1): the configurable"
  echo "\`max_export_findings\` cap, the \`snapshot_scope\` disclosure, and the"
  echo "client-side report of a body past the 8 MiB read limit."
  echo ""
  echo "| check | verdict | note |"
  echo "|---|---|---|"
  for i in "${!NAMES[@]}"; do
    echo "| ${NAMES[$i]} | ${VERDICTS[$i]} | ${NOTES[$i]} |"
  done
  echo ""
  echo "Verdict: **PASS**"
} > "${REPORT}"
color_green "PASS — report at ${REPORT}"
