#!/usr/bin/env bash
# Archived windows dropped instead of written (0.15.0).
#
# The daemon hands each scored window to its archive writer over a bounded
# channel and drops on full rather than blocking the analysis path. Before
# 0.15.0 that drop was invisible: `try_send` returned a boolean nobody read,
# and `seq` only advances after a successful write, so the hash chain could not
# show the gap either. A period could lose windows and still publish a
# perfectly coherent disclosure report.
#
# Since 0.15.0 every drop increments
# `perf_sentinel_archive_windows_dropped_total{reason}` over a bounded
# compile-time reason set, and every archived line carries the cumulative count
# so `disclose` can fold it into the period.
#
# Two legs, because no single daemon run proves both halves:
#
#   A. healthy archive, a real file. Every archived line carries a `drops`
#      field, and all four reasons are present at zero. A metric that only
#      appears once it fires cannot be alerted on, so its pre-warm is part of
#      the contract.
#
#   B. saturated archive, a FIFO. `CHANNEL_CAPACITY` is a compile-time 256, not
#      a config knob, so the channel cannot be shrunk to force the condition.
#      Pointing the archive at a FIFO nobody drains fills the pipe buffer, the
#      writer blocks inside `write_all`, the channel backs up and windows start
#      being dropped. `channel_full` climbs while the other three reasons stay
#      at zero, which is what tells a saturation apart from an I/O fault.
#
# What leg B does NOT assert: the exact drop count (it depends on pipe buffer
# size and scheduler timing, so only `> 0` is safe), and the arithmetic of the
# fold. A blocked FIFO yields no readable lines by construction, so the
# per-line accumulation and the period total are gated by the sibling
# hermetic scenario `disclose-archive-family-baseline` instead.
#
# Local binary, no cluster.

set -uo pipefail
# Job control off: the shell would otherwise print "Terminated" lines of its
# own every time the seeder or the fifo holder is killed, which reads like a
# failure in the middle of a passing scenario.
set +m

SCENARIO="archive-window-drops"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
# Short on purpose: the daemon's JSON socket lives here and a Unix socket path
# is capped near 104 bytes.
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
HTTP_PORT="${AWD_HTTP_PORT:-14550}"
GRPC_PORT="${AWD_GRPC_PORT:-14551}"
# 100ms is the configured floor and the fastest window cadence available, which
# is what makes the channel fill inside a short scenario.
FAST_TTL_MS="${AWD_FAST_TTL_MS:-100}"
SATURATE_SECS="${AWD_SATURATE_SECS:-40}"

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
SEED_PID=""
cleanup() {
  [ -n "${SEED_PID}" ] && kill "${SEED_PID}" 2>/dev/null
  # SIGKILL, not SIGTERM: a graceful shutdown drains the archive channel, and
  # in leg B that means writing hundreds of queued windows into a FIFO nobody
  # reads, which never returns.
  [ -n "${DAEMON_PID}" ] && kill -9 "${DAEMON_PID}" 2>/dev/null
}
trap cleanup EXIT

step "0. Pre-flight"
command -v python3 >/dev/null || die "python3 not on PATH"
command -v curl >/dev/null || die "curl not on PATH"
[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] \
  || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release first)"
ok "local binary at ${PERF_SENTINEL_LOCAL_BIN}"

cat > "${TMP_DIR}/seed.py" <<'PY'
import json, socket, sys, time
from datetime import datetime, timezone

sock_path, interval = sys.argv[1], float(sys.argv[2])
n = 0
while True:
    now = datetime.now(timezone.utc)
    ts = now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"
    tid = f"awd{n:029d}"
    # 8 sibling SELECTs clear n_plus_one_min_occurrences, so every window
    # carries a finding and is worth archiving.
    events = [{
        "timestamp": ts, "trace_id": tid, "span_id": f"s{i:015d}",
        "service": "shop-svc", "cloud_region": "eu-west-3",
        "type": "sql", "operation": "SELECT",
        "target": f"SELECT * FROM items WHERE order_id = {i}",
        "duration_us": 1500,
        "source": {"endpoint": "GET /orders", "method": "OrderService::list"},
    } for i in range(1, 9)]
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(sock_path)
        s.sendall((json.dumps(events) + "\n").encode())
        s.close()
    except OSError:
        pass
    n += 1
    time.sleep(interval)
PY

write_config() {  # $1 = archive path, $2 = trace_ttl_ms
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
trace_ttl_ms = $2
environment = "staging"

[daemon.ack]
enabled = false

[daemon.archive]
path = "$1"
# Well above anything this scenario writes: a rotation mid-run would reset the
# chain and muddy the reading.
max_size_mb = 1024

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

# Print the counter for one reason, or "absent".
drops_for() {
  curl -s "http://127.0.0.1:${HTTP_PORT}/metrics" \
    | awk -v r="$1" '$0 ~ "archive_windows_dropped_total\\{reason=\""r"\"\\}" {print $2; found=1}
                     END {if (!found) print "absent"}'
}

declare -a NAMES=() VERDICTS=() NOTES=()
record() { NAMES+=("$1"); VERDICTS+=("$2"); NOTES+=("$3"); }

# === Leg A: healthy archive ===
step "A. healthy archive: every line carries drops, all four reasons pre-warmed"
write_config "${TMP_DIR}/archive.ndjson" 500
start_daemon "d-healthy.log" || die "daemon did not start: $(tail -3 "${TMP_DIR}/d-healthy.log")"
python3 "${TMP_DIR}/seed.py" "${TMP_DIR}/s" 0.1 >/dev/null 2>&1 & SEED_PID=$!
disown "${SEED_PID}" 2>/dev/null || true
sleep 12
kill "${SEED_PID}" 2>/dev/null; SEED_PID=""
sleep 1

A_FULL="$(drops_for channel_full)"
A_EXIT="$(drops_for writer_exited)"
A_SER="$(drops_for serialize_error)"
A_WRITE="$(drops_for write_error)"
stop_daemon

if [ "${A_FULL}" = "0" ] && [ "${A_EXIT}" = "0" ] && [ "${A_SER}" = "0" ] && [ "${A_WRITE}" = "0" ]; then
  ok "all four reasons present at 0 (a metric that appears only once it fires cannot be alerted on)"
  record "reasons pre-warmed" PASS "channel_full/writer_exited/serialize_error/write_error all 0"
else
  fail "reasons read ${A_FULL}/${A_EXIT}/${A_SER}/${A_WRITE}, expected 0/0/0/0 (absent = not pre-warmed)"
  record "reasons pre-warmed" FAIL "${A_FULL}/${A_EXIT}/${A_SER}/${A_WRITE}"
fi

if note="$(python3 - "${TMP_DIR}/archive.ndjson" <<'PY'
import json, sys
lines = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(lines) >= 5, f"only {len(lines)} archived window(s), need at least 5"
missing = [i for i, l in enumerate(lines) if "drops" not in l]
assert not missing, f"{len(missing)} archived line(s) carry no drops field"
vals = [l["drops"] for l in lines]
assert all(a <= b for a, b in zip(vals, vals[1:])), f"drops went backwards: {vals}"
print(f"{len(lines)} windows, every line carries drops, non-decreasing")
PY
)"; then
  ok "${note}"
  record "drops stamped per line" PASS "${note}"
else
  fail "the archived lines do not carry a usable drops field"
  record "drops stamped per line" FAIL "see output above"
fi

# === Leg B: saturated archive ===
step "B. saturated archive: channel_full climbs, the other reasons stay at 0"
mkfifo "${TMP_DIR}/archive.fifo" || die "cannot create the fifo"
# A reader must exist or the daemon's open would block; it reads nothing, which
# is the point. Holding the read end open also keeps the writer from seeing
# EPIPE, so it blocks on a full pipe instead of erroring.
python3 -c "
import os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NONBLOCK)
while True:
    time.sleep(3600)
" "${TMP_DIR}/archive.fifo" >/dev/null 2>&1 &
HOLDER_PID=$!
disown "${HOLDER_PID}" 2>/dev/null || true

write_config "${TMP_DIR}/archive.fifo" "${FAST_TTL_MS}"
start_daemon "d-saturated.log" || die "daemon did not start: $(tail -3 "${TMP_DIR}/d-saturated.log")"
python3 "${TMP_DIR}/seed.py" "${TMP_DIR}/s" 0.01 >/dev/null 2>&1 & SEED_PID=$!
disown "${SEED_PID}" 2>/dev/null || true
sleep "${SATURATE_SECS}"
kill "${SEED_PID}" 2>/dev/null; SEED_PID=""
sleep 3

B_FULL="$(drops_for channel_full)"
B_EXIT="$(drops_for writer_exited)"
B_SER="$(drops_for serialize_error)"
B_WRITE="$(drops_for write_error)"
stop_daemon
kill "${HOLDER_PID}" 2>/dev/null

# Only `> 0` is safe: the exact count depends on the pipe buffer size and on
# how the scheduler interleaves the writer with the analysis path.
if [ "${B_FULL}" != "absent" ] && [ "${B_FULL}" -gt 0 ] 2>/dev/null \
   && [ "${B_SER}" = "0" ] && [ "${B_WRITE}" = "0" ] && [ "${B_EXIT}" = "0" ]; then
  ok "${B_FULL} windows dropped on channel_full, the other three reasons stayed at 0"
  record "saturation counted" PASS "channel_full=${B_FULL}, others 0"
else
  fail "channel_full=${B_FULL}, writer_exited=${B_EXIT}, serialize_error=${B_SER}, write_error=${B_WRITE}"
  fail "expected channel_full > 0 with the other three at 0"
  record "saturation counted" FAIL "${B_FULL}/${B_EXIT}/${B_SER}/${B_WRITE}"
fi

if grep -q "archive channel full, dropping window" "${TMP_DIR}/d-saturated.log"; then
  ok "the drop is logged with a pointer to the metric, not silently swallowed"
  record "drop logged" PASS "warning names the counter"
else
  fail "no drop warning in the daemon log"
  record "drop logged" FAIL "log silent"
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
