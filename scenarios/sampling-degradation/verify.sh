#!/usr/bin/env bash
# sampling-degradation: production almost always samples (head or tail) and
# collectors drop spans under pressure, yet the lab runs always_on and had
# never fed perf-sentinel a partial corpus. This scenario replays
# deterministic degraded variants of the committed astronomy-shop slices
# (trace-consistent sampling at 50/10/1% keep, plus 30% span loss with broken
# parentage) and locks the "degrades properly" contract. All variants are
# regenerated at run time by degrade.py - transforms are deterministic
# (FNV-1a on ids, the product's own daemon/sampling.rs hash), so keep-sets
# are nested across rates and nothing new is committed.
#
# Assertions (see README.md):
#   S0  die-guard, not an assertion: transforms actually degrade (keep counts
#       strictly decreasing, span-loss drops > 0) - a no-op transform must
#       abort the run, not vacuously pass it
#   A1  all 8 variants: analyze exit 0 + parseable JSON (never crashes,
#       even on a ~2-trace corpus or broken parent chains)
#   A2  degraded trace-sampled: total findings monotone non-increasing as
#       sampling deepens (sound because keep-sets are nested); total only -
#       per-class monotonicity would flake on legitimate reclassification
#   A3  every degraded variant: finding classes subset of the in-run degraded
#       baseline (no class invented from truncated fragments); manifest
#       intersection recorded per variant for recall visibility, not asserted
#   A4  clean trace-sampled: total findings <= fp_budget per rate (sampling
#       must never create false positives)
#   A5  degraded span-loss: traces_analyzed > 0 (counts unconstrained)
#   A6  clean span-loss: classes subset of the in-run clean baseline. Count
#       vs budget recorded informationally (broken parentage may reshape
#       timing statistics, so no budget assertion here)
set -uo pipefail

SCENARIO="sampling-degradation"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
FIXTURES="${SCRIPT_DIR}/../astronomy-shop/fixtures"
MANIFEST="${FIXTURES}/fixture-manifest.json"
CLEAN="${FIXTURES}/clean-slice.ndjson"
DEGRADED="${FIXTURES}/degraded-slice.ndjson"

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
  [ -s "${f}" ] || die "missing astronomy-shop fixture ${f} - run make capture-astronomy-shop"
done

manifest_get() {  # $1 = key ; lists joined by spaces
  python3 -c '
import json, sys
v = json.load(open(sys.argv[1]))[sys.argv[2]]
print(" ".join(v) if isinstance(v, list) else v)' "${MANIFEST}" "$1"
}
FP_BUDGET="$(manifest_get fp_budget)"
EXPECTED_CLASSES="$(manifest_get expected_finding_classes)"
case "${FP_BUDGET}" in *[!0-9]*|"") die "fp_budget not stamped in ${MANIFEST} - rerun capture.sh" ;; esac

run_analyze() {  # $1 = input file, $2 = tag ; json to out-<tag>.json, rc passthrough
  "${PERF_SENTINEL_LOCAL_BIN}" analyze --input "$1" \
    --format json > "${TMP_DIR}/out-$2.json" 2> "${TMP_DIR}/err-$2.txt"
}

traces_analyzed() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["analysis"]["traces_analyzed"])' "${TMP_DIR}/out-$1.json"; }

finding_classes() {  # all finding types, dedup sorted ; findings JSON (bare or wrapped)
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
items = d if isinstance(d, list) else d.get("findings", [])
def u(it): return it.get("finding", it) if isinstance(it, dict) else {}
print(" ".join(sorted(set(u(it).get("type", "") for it in items) - {""})))' "${TMP_DIR}/out-$1.json"
}

findings_total() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
items = d if isinstance(d, list) else d.get("findings", [])
print(len(items))' "${TMP_DIR}/out-$1.json"
}

extra_classes() {  # $1 = candidate classes, $2 = baseline classes ; prints candidate - baseline
  python3 -c '
import sys
c = set(sys.argv[1].split()) - {""}
b = set(sys.argv[2].split()) - {""}
print(" ".join(sorted(c - b)))' "$1" "$2"
}

common_count() {  # $1, $2 = space-joined class lists ; prints |intersection|
  python3 -c '
import sys
a = set(sys.argv[1].split()) - {""}
b = set(sys.argv[2].split()) - {""}
print(len(a & b))' "$1" "$2"
}

# ── S0: generate the 8 variants (die-guard: transforms must actually degrade)
step "S0: generate 8 deterministic variants under ${TMP_DIR}"
gen() {  # $1 = variant, $2 = source, $3 = mode, $4 = rate flag, $5 = rate
  python3 "${SCRIPT_DIR}/degrade.py" "$3" "$2" "${TMP_DIR}/$1.ndjson" "$4" "$5" \
    > "${TMP_DIR}/$1.stats" || die "degrade.py $3 $5 failed on $1"
  ok "$1: $(cat "${TMP_DIR}/$1.stats")"
}
gen deg-ts50   "${DEGRADED}" trace-sample --keep-rate 0.50
gen deg-ts10   "${DEGRADED}" trace-sample --keep-rate 0.10
gen deg-ts01   "${DEGRADED}" trace-sample --keep-rate 0.01
gen deg-sl30   "${DEGRADED}" span-loss    --drop-rate 0.30
gen clean-ts50 "${CLEAN}"    trace-sample --keep-rate 0.50
gen clean-ts10 "${CLEAN}"    trace-sample --keep-rate 0.10
gen clean-ts01 "${CLEAN}"    trace-sample --keep-rate 0.01
gen clean-sl30 "${CLEAN}"    span-loss    --drop-rate 0.30

stat_of() { sed -n "s/.*$2=\([0-9]*\).*/\1/p" "${TMP_DIR}/$1.stats"; }
for src in deg clean; do
  K50="$(stat_of "${src}-ts50" kept_traces)"
  K10="$(stat_of "${src}-ts10" kept_traces)"
  K01="$(stat_of "${src}-ts01" kept_traces)"
  # Strict decrease alone proves the transform degrades (a no-op keeps all
  # three equal). No absolute floor on the 1% count: a valid re-captured
  # slice may legitimately hash zero traces below 0.01, and an empty ts01
  # variant still satisfies A1/A2/A3 (traces_analyzed=0, empty subset).
  { [ "${K50}" -gt "${K10}" ] && [ "${K10}" -gt "${K01}" ]; } \
    || die "S0: ${src} keep counts not strictly decreasing (${K50}/${K10}/${K01}) - transform is a no-op or the fixture changed shape"
  [ "$(stat_of "${src}-sl30" dropped_spans)" -gt 0 ] \
    || die "S0: ${src} span-loss dropped nothing - transform is a no-op"
done

# ── baselines: analyze the untransformed slices (in-run, never hardcoded) ───
step "baseline: analyze both untransformed slices"
run_analyze "${DEGRADED}" deg-base || die "analyze failed on the untransformed degraded slice: $(tail -2 "${TMP_DIR}/err-deg-base.txt")"
DEG_BASE_TOTAL="$(findings_total deg-base)"
DEG_BASE_CLASSES="$(finding_classes deg-base)"
[ "$(traces_analyzed deg-base)" -gt 0 ] || die "degraded baseline analyzed zero traces"
run_analyze "${CLEAN}" clean-base || die "analyze failed on the untransformed clean slice: $(tail -2 "${TMP_DIR}/err-clean-base.txt")"
CLEAN_BASE_TOTAL="$(findings_total clean-base)"
CLEAN_BASE_CLASSES="$(finding_classes clean-base)"
ok "degraded: total=${DEG_BASE_TOTAL} classes=[${DEG_BASE_CLASSES}] ; clean: total=${CLEAN_BASE_TOTAL} classes=[${CLEAN_BASE_CLASSES}]"

# ── A1: no crash on any variant ─────────────────────────────────────────────
step "A1: all 8 variants analyze without crashing"
VARIANTS="deg-ts50 deg-ts10 deg-ts01 deg-sl30 clean-ts50 clean-ts10 clean-ts01 clean-sl30"
A1_BAD=""
for v in ${VARIANTS}; do
  if run_analyze "${TMP_DIR}/${v}.ndjson" "${v}" \
     && python3 -c 'import json,sys; json.load(open(sys.argv[1]))["analysis"]["traces_analyzed"]' "${TMP_DIR}/out-${v}.json" >/dev/null 2>&1; then
    :
  else
    A1_BAD="${A1_BAD:+${A1_BAD} }${v}"
  fi
done
if [ -z "${A1_BAD}" ]; then
  assert_pass "A1" "8/8 variants: exit 0 + parseable JSON with traces_analyzed"
else
  FIRST="${A1_BAD%% *}"
  assert_fail "A1" "crashed or invalid JSON on: ${A1_BAD} (first stderr: $(tail -1 "${TMP_DIR}/err-${FIRST}.txt" 2>/dev/null))"
fi

step "A2: degraded trace-sampled totals monotone non-increasing"
T50="$(findings_total deg-ts50 2>/dev/null || echo '?')"
T10="$(findings_total deg-ts10 2>/dev/null || echo '?')"
T01="$(findings_total deg-ts01 2>/dev/null || echo '?')"
if [ "${DEG_BASE_TOTAL}" -ge "${T50}" ] && [ "${T50}" -ge "${T10}" ] && [ "${T10}" -ge "${T01}" ] 2>/dev/null; then
  assert_pass "A2" "totals ${DEG_BASE_TOTAL} >= ${T50} >= ${T10} >= ${T01} at keep 100/50/10/1%"
else
  assert_fail "A2" "totals not monotone: ${DEG_BASE_TOTAL} / ${T50} / ${T10} / ${T01} at keep 100/50/10/1%"
fi

# ── A3: no class invented on any degraded variant ───────────────────────────
step "A3: degraded variants invent no finding class"
A3_BAD=""
for v in deg-ts50 deg-ts10 deg-ts01 deg-sl30; do
  C="$(finding_classes "${v}" 2>/dev/null)"
  EXTRA="$(extra_classes "${C}" "${DEG_BASE_CLASSES}")"
  [ -n "${EXTRA}" ] && A3_BAD="${A3_BAD:+${A3_BAD} }${v}:[${EXTRA}]"
  # recall visibility, recorded not asserted: classes shared with the manifest
  record "A3.${v}" "INFO - classes=[${C:-none}], manifest_common=$(common_count "${C}" "${EXPECTED_CLASSES}")"
done
if [ -z "${A3_BAD}" ]; then
  assert_pass "A3" "all degraded variants stay within baseline classes [${DEG_BASE_CLASSES}]"
else
  assert_fail "A3" "classes invented: ${A3_BAD} (baseline [${DEG_BASE_CLASSES}])"
fi

# ── A4: FP budget under sampling on the clean corpus ────────────────────────
step "A4: clean trace-sampled variants stay within fp_budget=${FP_BUDGET}"
for pair in 50:clean-ts50 10:clean-ts10 01:clean-ts01; do
  rate="${pair%%:*}"; v="${pair#*:}"
  TOTAL="$(findings_total "${v}" 2>/dev/null || echo '?')"
  if [ "${TOTAL}" != "?" ] && [ "${TOTAL}" -le "${FP_BUDGET}" ]; then
    assert_pass "A4-${rate}" "findings=${TOTAL} <= budget ${FP_BUDGET} at keep ${rate}%"
  else
    assert_fail "A4-${rate}" "findings=${TOTAL} exceeds budget ${FP_BUDGET} at keep ${rate}%"
  fi
done

step "A5: degraded span-loss variant still analyzes traces"
TA="$(traces_analyzed deg-sl30 2>/dev/null || echo 0)"
if [ "${TA}" -gt 0 ]; then
  assert_pass "A5" "traces_analyzed=${TA} on deg-sl30 (findings=$(findings_total deg-sl30 2>/dev/null || echo '?'), unconstrained by design)"
else
  assert_fail "A5" "traces_analyzed=${TA} on deg-sl30"
fi

step "A6: clean span-loss variant invents no finding class"
C="$(finding_classes clean-sl30 2>/dev/null)"
EXTRA="$(extra_classes "${C}" "${CLEAN_BASE_CLASSES}")"
TOTAL="$(findings_total clean-sl30 2>/dev/null || echo '?')"
if [ -z "${EXTRA}" ]; then
  assert_pass "A6" "classes=[${C:-none}] subset of clean baseline [${CLEAN_BASE_CLASSES:-none}]; findings=${TOTAL} vs budget ${FP_BUDGET} (informational)"
else
  assert_fail "A6" "new classes [${EXTRA}] beyond clean baseline [${CLEAN_BASE_CLASSES:-none}]"
fi

# =============================================================================
verdict=$([ "${FAILS}" -eq 0 ] && echo PASS || echo FAIL)
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "perf-sentinel vs sampled/partial corpora: deterministic trace-sampled and"
  echo "span-loss variants of the committed astronomy-shop slices, replayed with"
  echo "the local binary. Contract: never crash, degrade monotonically, invent no"
  echo "class, keep the clean corpus under its FP budget."
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
