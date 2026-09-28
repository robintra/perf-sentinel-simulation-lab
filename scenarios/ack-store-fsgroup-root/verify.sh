#!/usr/bin/env bash
# ack-store-fsgroup-root: the daemon's start-up chmod of the ack store
# directory, against the volume shape a Kubernetes fsGroup gives it, and the
# start-up advisories of the chart's configuration.
#
# The Helm chart puts the ack store at the root of its volume. Under the pod's
# fsGroup that root belongs to root, group fsGroup, mode 2775, and the daemon
# runs as 65534: its chmod to 0700 always fails with EPERM. perf-sentinel
# 0.25.2 and older warned about it at every start. 0.25.3 logs it at debug,
# and keeps the warning for a directory other users can write into.
#
# The chart's configuration listens on 0.0.0.0. Up to 0.25.2 `watch` validated
# its configuration twice, before and after its command-line flags, so the
# non-loopback advisory printed twice. 0.25.3 validates once, flags applied.
#
# No cluster: a Docker volume prepared as root reproduces the kubelet's result
# (owner root, group 65534, setgid, group-writable), and the image runs as
# 65534:65534 like the chart's securityContext.
#
# Assertions (see README.md):
#   F1  fsGroup shape (root:65534 2775): no warning at start.
#   F2  the same start at RUST_LOG=debug logs the refusal at debug.
#   F3  an ack posted to that daemon answers 201.
#   F4  acks.jsonl is 600, owned by 65534, the directory is left at 2775.
#   W1  world-writable (root:65534 2777): the warning stays.
#   O1  a directory the daemon owns (65534:65534 2775): no warning, tightened
#       to 700.
#   L1  listen_address = "0.0.0.0" in the file: the advisory prints once.
#   L2  --listen-address 0.0.0.0 on the command line: the advisory prints once
#       and the daemon answers on the published port.
#
# Needs Docker. The image resolves through scripts/resolve-image.sh.
set -uo pipefail

SCENARIO="ack-store-fsgroup-root"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/resolve-image.sh
. "${LAB_ROOT}/scripts/resolve-image.sh"
UTIL_IMAGE="${UTIL_IMAGE:-busybox:1.37}"
PORT="${PORT:-15430}"
PREFIX="asfr"
WARN_MSG="could not tighten ack store parent directory to 0700"
DEBUG_MSG="ack store parent directory is not ours to tighten to 0700"
SIG="n_plus_one_sql:ack-lab:_orders:0123456789abcdef0123456789abcdef"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

FAILS=0
declare -a SUMMARY
record() { SUMMARY+=("$1|$2"); }
assert_pass() { ok "$2"; record "$1" "PASS — $2"; }
assert_fail() { color_red "    FAIL: $2"; FAILS=$((FAILS + 1)); record "$1" "FAIL — $2"; }

cleanup() {
  docker rm -f "${PREFIX}-daemon" >/dev/null 2>&1 || true
  for v in fsgroup world own; do docker volume rm -f "${PREFIX}-${v}" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

command -v docker >/dev/null || die "docker not found"
command -v curl >/dev/null || die "curl not found"
step "image under test: ${IMAGE}"

rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"
cleanup
# listen_address 0.0.0.0 so the published port reaches the daemon.
cat > "${TMP_DIR}/config.toml" <<'EOF'
[daemon]
listen_address = "0.0.0.0"

[daemon.ack]
storage_path = "/data/acks.jsonl"
EOF
grep -v '^listen_address' "${TMP_DIR}/config.toml" > "${TMP_DIR}/config-flags.toml"
NONLOOPBACK_MSG="Daemon configured to listen on non-loopback address"

# prepare <volume> <owner:group> <mode>: the volume root as the kubelet leaves it.
prepare() {
  docker volume create "${PREFIX}-$1" > /dev/null
  docker run --rm -v "${PREFIX}-$1:/data" "${UTIL_IMAGE}" \
    sh -c "chown $2 /data && chmod $3 /data" || die "cannot prepare volume $1"
}

# start <volume> [RUST_LOG [config file [watch flags...]]]: run the daemon as
# 65534 until /health answers.
start() {
  local volume="$1" level="${2:-info}" config="${3:-config.toml}"
  shift $(($# < 3 ? $# : 3))
  docker rm -f "${PREFIX}-daemon" > /dev/null 2>&1 || true
  docker run -d --name "${PREFIX}-daemon" --user 65534:65534 \
    -e RUST_LOG="${level}" \
    -v "${PREFIX}-${volume}:/data" -v "${TMP_DIR}/${config}:/etc/perf-sentinel/config.toml:ro" \
    -p "127.0.0.1:${PORT}:4318" \
    "${IMAGE}" watch -c /etc/perf-sentinel/config.toml "$@" > /dev/null || die "cannot start ${IMAGE}"
  for _ in $(seq 40); do curl -sf "http://127.0.0.1:${PORT}/health" > /dev/null && return 0; sleep 0.5; done
  docker logs "${PREFIX}-daemon" > "${TMP_DIR}/${volume}-failed.log" 2>&1
  die "daemon on volume ${volume} never answered /health, see ${TMP_DIR}/${volume}-failed.log"
}

# logs_to <file>: the daemon's logs so far, colour codes stripped.
logs_to() { docker logs "${PREFIX}-daemon" 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g' > "$1"; }

# stat_of <volume> <path>: `<mode> <uid>:<gid>`, or `missing`.
stat_of() {
  docker run --rm -v "${PREFIX}-$1:/data" "${UTIL_IMAGE}" \
    sh -c "stat -c '%a %u:%g' $2 2>/dev/null || echo missing"
}

# =============================================================================
step "F: fsGroup shape, root:65534 2775"
prepare fsgroup 0:65534 2775
start fsgroup
logs_to "${TMP_DIR}/F-info.log"
if grep -q "${WARN_MSG}" "${TMP_DIR}/F-info.log"; then
  assert_fail "F1" "warning at start: $(grep -m1 "${WARN_MSG}" "${TMP_DIR}/F-info.log" | cut -c1-160)"
else
  assert_pass "F1" "no warning about the ack store directory at start"
fi
n="$(grep -c "${NONLOOPBACK_MSG}" "${TMP_DIR}/F-info.log")"
if [ "${n}" = "1" ]; then
  assert_pass "L1" "listen_address 0.0.0.0 in the file: the non-loopback advisory prints once"
else
  assert_fail "L1" "listen_address 0.0.0.0 in the file: the non-loopback advisory prints ${n} times"
fi
code="$(curl -s -o "${TMP_DIR}/F-ack.body" -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' -d '{"by":"lab","reason":"fsgroup volume"}' \
  "http://127.0.0.1:${PORT}/api/findings/${SIG}/ack")"
if [ "${code}" = "201" ]; then
  assert_pass "F3" "ack posted to the daemon on that volume: 201"
else
  assert_fail "F3" "ack answered ${code}: $(cat "${TMP_DIR}/F-ack.body")"
fi
start fsgroup debug
logs_to "${TMP_DIR}/F-debug.log"
if grep -q "DEBUG.*${DEBUG_MSG}" "${TMP_DIR}/F-debug.log" && ! grep -q "${WARN_MSG}" "${TMP_DIR}/F-debug.log"; then
  assert_pass "F2" "at RUST_LOG=debug the refusal logs at debug, not warn"
else
  assert_fail "F2" "debug run: $(grep -m1 'ack store parent' "${TMP_DIR}/F-debug.log" | cut -c1-160)"
fi
docker rm -f "${PREFIX}-daemon" > /dev/null
got="$(stat_of fsgroup /data/acks.jsonl) / $(stat_of fsgroup /data)"
if [ "${got}" = "600 65534:65534 / 2775 0:65534" ]; then
  assert_pass "F4" "acks.jsonl 600 owned by 65534, directory left at 2775 root:65534"
else
  assert_fail "F4" "acks.jsonl / directory: ${got}"
fi

# =============================================================================
step "W: world-writable, root:65534 2777"
prepare world 0:65534 2777
start world
logs_to "${TMP_DIR}/W.log"
docker rm -f "${PREFIX}-daemon" > /dev/null
if grep -q "WARN.*${WARN_MSG}" "${TMP_DIR}/W.log"; then
  assert_pass "W1" "a directory other users can write into still warns"
else
  assert_fail "W1" "no warning on a world-writable directory"
fi

# =============================================================================
step "O: the daemon's own directory, 65534:65534 2775"
prepare own 65534:65534 2775
start own
logs_to "${TMP_DIR}/O.log"
docker rm -f "${PREFIX}-daemon" > /dev/null
got="$(stat_of own /data)"
if ! grep -q "ack store parent" "${TMP_DIR}/O.log" && [ "${got}" = "700 65534:65534" ]; then
  assert_pass "O1" "no ack store log line, directory tightened to 700"
else
  assert_fail "O1" "directory ${got}, log: $(grep -m1 'ack store parent' "${TMP_DIR}/O.log" | cut -c1-160)"
fi

# =============================================================================
step "L2: the listen address from the command line"
start own info config-flags.toml --listen-address 0.0.0.0 --listen-port-http 4318
logs_to "${TMP_DIR}/L2.log"
docker rm -f "${PREFIX}-daemon" > /dev/null
n="$(grep -c "${NONLOOPBACK_MSG}" "${TMP_DIR}/L2.log")"
if [ "${n}" = "1" ]; then
  assert_pass "L2" "--listen-address 0.0.0.0: the advisory prints once, /health answers"
else
  assert_fail "L2" "--listen-address 0.0.0.0: the advisory prints ${n} times"
fi

# =============================================================================
verdict=$([ "${FAILS}" -eq 0 ] && echo PASS || echo FAIL)
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "The ack store directory chmod of ${IMAGE}, on the volume shape a"
  echo "Kubernetes fsGroup leaves, a world-writable one and one the daemon owns."
  echo ""
  echo "| assertion | result |"
  echo "|---|---|"
  for row in "${SUMMARY[@]}"; do
    printf "| %s | %s |\n" "${row%%|*}" "${row#*|}"
  done
  echo ""
  echo "Verdict: **${verdict}**"
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  color_green "PASS — report at ${REPORT}"
else
  die "FAIL (${FAILS} assertion(s)) — report at ${REPORT}"
fi
