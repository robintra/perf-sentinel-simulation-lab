#!/usr/bin/env bash
# astronomy-shop: replay perf-sentinel against the OpenTelemetry Astronomy Shop
# demo - capture-once/replay-forever. The committed fixtures are two curated
# NDJSON slices of Collector file-exporter output (clean = normal mixed traffic,
# degraded = a recorded flagd failure-flag set), captured by capture.sh from the
# upstream docker compose demo, OUTSIDE the lab cluster. This exercises the two
# things the lab cannot produce itself: foreign community auto-instrumentation,
# and a false-positive budget on realistic legitimate traffic.
#
# Assertions (see README.md):
#   R1  analyze on the degraded slice: exit 0, traces_analyzed > 0, and the
#       finding classes intersect the manifest's expected_finding_classes
#       (loose ground truth - we do not control Astronomy Shop internals).
#   F1  analyze on the clean slice: exit 0, traces_analyzed > 0, and the TOTAL
#       finding count stays <= the manifest's fp_budget (stamped from the
#       observed count at curation time). Actual classes are emitted into the
#       report even on PASS so a class shift under budget stays visible.
#   F2  report --input <clean slice> renders a usable dashboard.
set -uo pipefail

SCENARIO="astronomy-shop"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
MANIFEST="${SCRIPT_DIR}/fixtures/fixture-manifest.json"
CLEAN="${SCRIPT_DIR}/fixtures/clean-slice.ndjson"
DEGRADED="${SCRIPT_DIR}/fixtures/degraded-slice.ndjson"

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
for f in "${MANIFEST}" "${CLEAN}" "${DEGRADED}"; do
  [ -s "${f}" ] || die "missing fixture ${f} - run scenarios/astronomy-shop/capture.sh (make capture-astronomy-shop) to capture and curate the slices"
done

# Guard: R1's recall depends on the empty-list attributes ("arrayValue":{},
# canonical protojson that omits empty repeated fields) which community
# auto-instrumentation emits under the failure flag. This coverage is incidental
# to the slice, so fail fast if a recapture ever drops those lines rather than
# letting the ingest regression test vanish silently.
grep -q '"arrayValue":{}' "${DEGRADED}" || die "degraded slice lost its empty-arrayValue lines (ingest coverage gone), recapture from a flagd failure set that emits them"

manifest_get() {  # $1 = key ; lists joined by spaces
  python3 -c '
import json, sys
v = json.load(open(sys.argv[1]))[sys.argv[2]]
print(" ".join(v) if isinstance(v, list) else v)' "${MANIFEST}" "$1"
}
FP_BUDGET="$(manifest_get fp_budget)"
EXPECTED_CLASSES="$(manifest_get expected_finding_classes)"
case "${FP_BUDGET}" in *[!0-9]*|"") die "fp_budget not stamped in ${MANIFEST} - rerun capture.sh" ;; esac

# Default detection config on purpose: the demo spans are canonical OTel
# semconv from community auto-instrumentation (unlike batch-otlp-file's
# pre-obfuscated dd-trace SQL that forces strict mode). R1 and F1 must run
# under the SAME config: the FP budget is only meaningful measured under the
# config that produced the recall.
run_analyze() {  # $1 = input file ; stdout->out.json stderr->err.txt ; rc passthrough
  "${PERF_SENTINEL_LOCAL_BIN}" analyze --input "$1" \
    --format json > "${TMP_DIR}/out.json" 2> "${TMP_DIR}/err.txt"
}

traces_analyzed() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["analysis"]["traces_analyzed"])' "${TMP_DIR}/out.json"; }

finding_classes() {  # all services, dedup sorted ; findings JSON (bare or wrapped) in out.json
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
items = d if isinstance(d, list) else d.get("findings", [])
def u(it): return it.get("finding", it) if isinstance(it, dict) else {}
print(" ".join(sorted(set(u(it).get("type", "") for it in items) - {""})))' "${TMP_DIR}/out.json"
}

findings_total() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
items = d if isinstance(d, list) else d.get("findings", [])
print(len(items))' "${TMP_DIR}/out.json"
}

# ── R1: recall on the degraded slice ────────────────────────────────────────
step "R1: analyze degraded slice - an expected finding class is present"
if run_analyze "${DEGRADED}"; then
  TA="$(traces_analyzed)"
  DEG_CLASSES="$(finding_classes)"
  COMMON="$(python3 -c '
import sys
e = set(sys.argv[1].split()) - {""}
g = set(sys.argv[2].split()) - {""}
print(len(e & g))' "${EXPECTED_CLASSES}" "${DEG_CLASSES}")"
  if [ "${TA}" -gt 0 ] && [ "${COMMON}" -ge 1 ]; then
    assert_pass "R1" "traces_analyzed=${TA}, classes=[${DEG_CLASSES}], ${COMMON} common with expected [${EXPECTED_CLASSES}]"
  else
    assert_fail "R1" "traces_analyzed=${TA}, classes=[${DEG_CLASSES}] vs expected [${EXPECTED_CLASSES}]"
  fi
else
  assert_fail "R1" "analyze exited non-zero on the degraded slice: $(tail -2 "${TMP_DIR}/err.txt")"
fi

# ── F1: false-positive budget on the clean slice ────────────────────────────
step "F1: analyze clean slice - total findings within fp_budget=${FP_BUDGET}"
if run_analyze "${CLEAN}"; then
  TA="$(traces_analyzed)"
  TOTAL="$(findings_total)"
  CLEAN_CLASSES="$(finding_classes)"
  # traces_analyzed > 0 guards against a degenerate empty slice trivially
  # passing the budget. Classes are recorded even on PASS: a regression that
  # stays under budget but shifts class must remain visible in the report.
  if [ "${TA}" -gt 0 ] && [ "${TOTAL}" -le "${FP_BUDGET}" ]; then
    assert_pass "F1" "traces_analyzed=${TA}, findings=${TOTAL} <= budget ${FP_BUDGET}, classes=[${CLEAN_CLASSES:-none}]"
  else
    assert_fail "F1" "traces_analyzed=${TA}, findings=${TOTAL} > budget ${FP_BUDGET}, classes=[${CLEAN_CLASSES:-none}]"
  fi
else
  assert_fail "F1" "analyze exited non-zero on the clean slice: $(tail -2 "${TMP_DIR}/err.txt")"
fi

# ── M1: real broker spans are ingested as messaging I/O ─────────────────────
# The demo's checkout service publishes to Kafka and accounting /
# fraud-detection consume from it, so these slices carry PRODUCER spans from
# canonical, community-maintained instrumentation we did not author. Until the
# messaging block landed they were dropped as `not_io`; the count is what proves
# a real emitter reaches the detector, not a fixture built on our assumptions.
#
# Counted, not merely non-zero: the slices are frozen, so the number is a
# contract like fp_budget. Findings are NOT asserted here — the demo publishes
# one message per checkout, so there is no messaging anti-pattern to find, and
# claiming otherwise would be asserting nothing.
step "M1: real Kafka PRODUCER spans are counted as messaging I/O ops"
M1_FAILS=0
for slice_name in clean degraded; do
  case "${slice_name}" in
    clean) slice_path="${CLEAN}"; want=13 ;;
    *)     slice_path="${DEGRADED}"; want=10 ;;
  esac
  if run_analyze "${slice_path}"; then
    got="$(python3 -c "
import json
g = json.load(open('${TMP_DIR}/out.json')).get('green_summary') or {}
print(g.get('total_messaging_io_ops') or 0)" 2>/dev/null || echo 0)"
    if [ "${got}" = "${want}" ]; then
      ok "${slice_name}: total_messaging_io_ops=${got} (matches the PRODUCER span count in the slice)"
    else
      color_red "    FAIL: ${slice_name}: total_messaging_io_ops=${got}, expected ${want}"
      M1_FAILS=$((M1_FAILS + 1))
    fi
  else
    color_red "    FAIL: analyze exited non-zero on the ${slice_name} slice"
    M1_FAILS=$((M1_FAILS + 1))
  fi
done
if [ "${M1_FAILS}" -eq 0 ]; then
  assert_pass "M1" "both slices ingest their real Kafka publishes as messaging I/O (13 clean / 10 degraded)"
else
  assert_fail "M1" "${M1_FAILS} slice(s) did not ingest the expected messaging op count"
fi

# ── F2: report on the clean slice ───────────────────────────────────────────
step "F2: report --input <clean slice> renders a usable dashboard"
if "${PERF_SENTINEL_LOCAL_BIN}" report --input "${CLEAN}" \
     --output "${TMP_DIR}/r.html" > /dev/null 2> "${TMP_DIR}/err.txt" \
   && [ -s "${TMP_DIR}/r.html" ] && grep -q "frontend" "${TMP_DIR}/r.html"; then
  assert_pass "F2" "dashboard rendered from the clean slice ($(wc -c < "${TMP_DIR}/r.html" | tr -d ' ') bytes, frontend present)"
else
  assert_fail "F2" "report failed or dashboard empty: $(tail -2 "${TMP_DIR}/err.txt")"
fi

# =============================================================================
verdict=$([ "${FAILS}" -eq 0 ] && echo PASS || echo FAIL)
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "perf-sentinel vs the OpenTelemetry Astronomy Shop demo: recall on foreign"
  echo "auto-instrumentation plus a false-positive budget on committed slices."
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
