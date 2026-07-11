#!/usr/bin/env bash
# prod-topology-replay: replay a committed slice of REAL production
# topology - the Alibaba cluster-trace-microservices-v2022 call graphs
# (17k+ microservices, 20M+ call graphs over 13 days; hashed service
# names, hierarchical rpc_id parentage, real timing). This is the one
# corpus shape the lab cannot synthesize and astronomy-shop cannot
# provide: production-scale topology, fanout, chains, and service
# cardinality. Attributes are a documented synthetic carrier
# (http://<dm>/<interface>) - what is validated here is the TOPOLOGICAL
# detector surface and ingest at real-world trace shapes, not
# query-shape detection (see README).
#
# Assertions (see README.md):
#   T1  analyze on the slice: exit 0 and traces_analyzed equals the
#       manifest's stamped value (deterministic committed input)
#   T2  every manifest finding class is present (recall on real
#       production topology; classes were stamped at curation time)
#   T3  total findings equal the stamped count - replay is
#       deterministic, so any drift forces a human look; restamping is
#       a deliberate act (rerun fetch.sh, see README)
#   T4  structural guard: fixture line count equals the manifest's
#       trace count (one ExportTraceServiceRequest per trace)
#   T5  report --input renders a usable dashboard naming an MS_ service
set -uo pipefail

SCENARIO="prod-topology-replay"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
MANIFEST="${SCRIPT_DIR}/fixtures/fixture-manifest.json"
SLICE="${SCRIPT_DIR}/fixtures/alibaba-slice.ndjson"

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
command -v python3 >/dev/null 2>&1 || die "python3 required"
for f in "${MANIFEST}" "${SLICE}"; do
  [ -s "${f}" ] || die "missing fixture ${f} - run scenarios/prod-topology-replay/fetch.sh (make fetch-prod-topology) to download and curate the slice"
done

manifest_get() {  # $1 = key ; lists joined by spaces
  python3 -c '
import json, sys
v = json.load(open(sys.argv[1]))[sys.argv[2]]
print(" ".join(v) if isinstance(v, list) else v)' "${MANIFEST}" "$1"
}
M_TRACES="$(manifest_get traces)"
M_ANALYZED="$(manifest_get traces_analyzed)"
M_TOTAL="$(manifest_get findings_total)"
M_CLASSES="$(manifest_get expected_finding_classes)"
case "${M_TOTAL}" in *[!0-9]*|"") die "findings_total not stamped in ${MANIFEST} - rerun fetch.sh" ;; esac

step "T4: structural guard - one request line per curated trace"
LINES="$(grep -c "" "${SLICE}")"
if [ "${LINES}" -eq "${M_TRACES}" ]; then
  assert_pass "T4" "${LINES} lines == ${M_TRACES} curated traces"
else
  assert_fail "T4" "${LINES} lines != ${M_TRACES} curated traces (fixture/manifest drift)"
fi

step "T1: analyze the committed slice"
if "${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${SLICE}" \
     --format json > "${TMP_DIR}/out.json" 2> "${TMP_DIR}/err.txt"; then
  TA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["analysis"]["traces_analyzed"])' "${TMP_DIR}/out.json")"
  if [ "${TA}" = "${M_ANALYZED}" ]; then
    assert_pass "T1" "traces_analyzed=${TA} == stamped ${M_ANALYZED}"
  else
    assert_fail "T1" "traces_analyzed=${TA} != stamped ${M_ANALYZED}"
  fi
else
  assert_fail "T1" "analyze exited non-zero: $(tail -2 "${TMP_DIR}/err.txt")"
  TA=0
fi

OBSERVED_CLASSES="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
items = d if isinstance(d, list) else d.get("findings", [])
def u(it): return it.get("finding", it) if isinstance(it, dict) else {}
print(" ".join(sorted(set(u(it).get("type", "") for it in items) - {""})))' "${TMP_DIR}/out.json" 2>/dev/null)"
OBSERVED_TOTAL="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
items = d if isinstance(d, list) else d.get("findings", [])
print(len(items))' "${TMP_DIR}/out.json" 2>/dev/null || echo '?')"

step "T2: every stamped topological class is still found"
MISSING="$(python3 -c '
import sys
expected = set(sys.argv[1].split()) - {""}
got = set(sys.argv[2].split()) - {""}
print(" ".join(sorted(expected - got)))' "${M_CLASSES}" "${OBSERVED_CLASSES}")"
if [ -z "${MISSING}" ]; then
  assert_pass "T2" "classes [${OBSERVED_CLASSES:-none}] cover stamped [${M_CLASSES:-none}]"
else
  assert_fail "T2" "missing stamped classes [${MISSING}] (observed [${OBSERVED_CLASSES:-none}])"
fi

step "T3: deterministic finding count matches the stamp"
if [ "${OBSERVED_TOTAL}" = "${M_TOTAL}" ]; then
  assert_pass "T3" "findings=${OBSERVED_TOTAL} == stamped ${M_TOTAL}"
else
  assert_fail "T3" "findings=${OBSERVED_TOTAL} != stamped ${M_TOTAL} - detector drift on real topology, restamp deliberately if intended (README)"
fi

step "T5: report --input renders a dashboard from the slice"
if "${PERF_SENTINEL_LOCAL_BIN}" report --input "${SLICE}" \
     --output "${TMP_DIR}/r.html" > /dev/null 2> "${TMP_DIR}/err.txt" \
   && [ -s "${TMP_DIR}/r.html" ] && grep -q "MS_" "${TMP_DIR}/r.html"; then
  assert_pass "T5" "dashboard rendered ($(wc -c < "${TMP_DIR}/r.html" | tr -d ' ') bytes, MS_ services present)"
else
  assert_fail "T5" "report failed or dashboard empty: $(tail -2 "${TMP_DIR}/err.txt")"
fi

# =============================================================================
verdict=$([ "${FAILS}" -eq 0 ] && echo PASS || echo FAIL)
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "perf-sentinel vs real production topology: a committed OTLP slice"
  echo "converted from the Alibaba v2022 microservice call graphs, asserting"
  echo "deterministic ingest and the topological detector surface."
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
