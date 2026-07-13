#!/usr/bin/env bash
# chaos-replay: replay a committed slice of live CHAOS telemetry - the OTel
# Astronomy Shop demo driven through failure flags, a mid-tier service
# SIGKILL and a paused dependency (see capture.sh) - and assert that
# perf-sentinel degrades cleanly on the telemetry of a system genuinely
# failing. This is the corpus shape the offline transforms cannot produce:
# real ERROR spans, structural half-traces (children exported, parents died
# in the killed service's exporter buffer), client timeouts.
#
# Assertions (see README.md):
#   X1  analyze on the slice: exit 0, traces_analyzed equals the stamped
#       value, no panic on stderr (clean degradation, not survival by luck)
#   X2  per-class finding census equals the stamped census - deterministic
#       replay, so any drift (count OR an invented class) forces a human
#       look; restamping is a deliberate act (rerun capture.sh)
#   X3  chaos guard: the slice still contains the stamped number of ERROR
#       spans and broken-parent traces - proves the committed corpus is
#       actually chaotic, so X1/X2 can never pass vacuously on a tame slice
#   X4  report --input renders a usable dashboard from the chaos slice
set -uo pipefail

SCENARIO="chaos-replay"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
rm -rf "${TMP_DIR}"
rm -f "${REPORT}"   # a preflight die must never cat a stale prior-run verdict
mkdir -p "${TMP_DIR}"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
MANIFEST="${SCRIPT_DIR}/fixtures/fixture-manifest.json"
SLICE="${SCRIPT_DIR}/fixtures/chaos-slice.ndjson"
CENSUS="${SCRIPT_DIR}/chaos_census.py"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

FAILS=0
declare -a SUMMARY
record() { SUMMARY+=("$1|$2"); }
assert_pass() { ok "$2"; record "$1" "PASS - $2"; }
assert_fail() { color_red "    FAIL: $2"; FAILS=$((FAILS + 1)); record "$1" "FAIL - $2"; }

[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release first)"
for c in python3 jq; do command -v "$c" >/dev/null 2>&1 || die "$c required"; done
for f in "${MANIFEST}" "${SLICE}"; do
  [ -s "${f}" ] || die "missing fixture ${f} - run scenarios/chaos-replay/capture.sh (make capture-chaos-replay) to capture and curate the slice"
done

M_ANALYZED="$(jq -r '.traces_analyzed' "${MANIFEST}")"
M_ERR="$(jq -r '.error_spans' "${MANIFEST}")"
M_BROKEN="$(jq -r '.broken_parent_traces' "${MANIFEST}")"
M_CENSUS="$(jq -cS '.finding_census' "${MANIFEST}")"
for v in "${M_ANALYZED}" "${M_ERR}" "${M_BROKEN}"; do
  case "${v}" in *[!0-9]*|"") die "manifest not stamped (rerun capture.sh)" ;; esac
done
# Anti-vacuity floor: this gate's headline is clean degradation on genuinely
# chaotic telemetry. A stamp with zero ERROR spans or zero broken-parent
# traces means the choreography never bit - X1/X2 would pass on a tame
# corpus. Look before restamping.
[ "${M_ERR}" -gt 0 ] && [ "${M_BROKEN}" -gt 0 ] && [ "${M_ANALYZED}" -gt 0 ] && [ "${M_CENSUS}" != "null" ] \
  || die "manifest stamps a tame corpus (error_spans=${M_ERR} broken_parent_traces=${M_BROKEN} traces_analyzed=${M_ANALYZED}) - investigate before rerunning capture.sh"

step "X3: chaos guard - the committed slice is still the stamped chaotic corpus"
SLICE_STATS="$(python3 "${CENSUS}" slice "${SLICE}")" || die "chaos census failed on the slice"
O_ERR="$(jq -r '.error_spans' <<< "${SLICE_STATS}")"
O_BROKEN="$(jq -r '.broken_parent_traces' <<< "${SLICE_STATS}")"
if [ "${O_ERR}" = "${M_ERR}" ] && [ "${O_BROKEN}" = "${M_BROKEN}" ]; then
  assert_pass "X3" "error_spans=${O_ERR}, broken_parent_traces=${O_BROKEN} == stamps"
else
  assert_fail "X3" "slice census (err=${O_ERR} broken=${O_BROKEN}) != stamps (err=${M_ERR} broken=${M_BROKEN}) - fixture/manifest drift"
fi

step "X1: analyze the chaos slice (clean degradation)"
if "${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${SLICE}" \
     --format json > "${TMP_DIR}/out.json" 2> "${TMP_DIR}/err.txt"; then
  FINDING_STATS="$(python3 "${CENSUS}" findings "${TMP_DIR}/out.json")" \
    || die "chaos_census.py findings failed on ${TMP_DIR}/out.json - helper bug, not census drift"
  TA="$(jq -r '.traces_analyzed // 0' <<< "${FINDING_STATS}")"
  if grep -q "panicked at" "${TMP_DIR}/err.txt"; then
    assert_fail "X1" "a thread panicked during analyze (stderr: $(grep -m1 'panicked at' "${TMP_DIR}/err.txt"))"
  elif [ "${TA}" = "${M_ANALYZED}" ]; then
    assert_pass "X1" "exit 0, traces_analyzed=${TA} == stamped ${M_ANALYZED}, no panic"
  else
    assert_fail "X1" "traces_analyzed=${TA} != stamped ${M_ANALYZED}"
  fi
else
  assert_fail "X1" "analyze exited non-zero on the chaos slice: $(tail -2 "${TMP_DIR}/err.txt")"
  FINDING_STATS='{}'
fi

step "X2: per-class finding census matches the stamp"
O_CENSUS="$(jq -cS '.finding_census // {}' <<< "${FINDING_STATS}")"
if [ "${O_CENSUS}" = "${M_CENSUS}" ]; then
  assert_pass "X2" "census ${O_CENSUS} == stamp"
else
  assert_fail "X2" "census drift on chaos telemetry: observed ${O_CENSUS} vs stamped ${M_CENSUS} - restamp deliberately if intended (README)"
fi

step "X4: report --input renders a dashboard from the chaos slice"
if "${PERF_SENTINEL_LOCAL_BIN}" report --input "${SLICE}" \
     --output "${TMP_DIR}/r.html" > /dev/null 2> "${TMP_DIR}/err.txt" \
   && [ -s "${TMP_DIR}/r.html" ] && grep -q "frontend" "${TMP_DIR}/r.html"; then
  assert_pass "X4" "dashboard rendered ($(wc -c < "${TMP_DIR}/r.html" | tr -d ' ') bytes, demo services present)"
else
  assert_fail "X4" "report failed or dashboard empty: $(tail -2 "${TMP_DIR}/err.txt")"
fi

# =============================================================================
verdict=$([ "${FAILS}" -eq 0 ] && echo PASS || echo FAIL)
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "perf-sentinel vs the telemetry of a system genuinely failing: a"
  echo "committed slice of the OTel demo driven through failure flags, a"
  echo "mid-tier SIGKILL and a paused dependency, asserting clean degradation"
  echo "and a deterministic finding census."
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
  color_green "PASS - report at ${REPORT}"
else
  die "FAIL (${FAILS} assertion(s)) - report at ${REPORT}"
fi
