#!/usr/bin/env bash
# semconv-drift: OTel renamed the attribute keys the detectors read
# (db.statement -> db.query.text, db.system -> db.system.name,
# http.method -> http.request.method, http.url -> url.full) and real fleets
# emit any mix of both generations during the migration
# (OTEL_SEMCONV_STABILITY_OPT_IN). The product ingest is dual-keyed with a
# documented preference per pair (db.system.name is NEW-preferred, the other
# three are OLD-preferred), but the lab never isolated the stable-only shape:
# the astronomy capture dual-emits per service, and every lab generator uses
# the legacy keys, so a pure db.query.text span had zero scenario coverage.
# This scenario rewrites the degraded astronomy slice into the three pure
# shapes (old-only / new-only / dup) and asserts the findings are IDENTICAL
# to the untransformed baseline - strict per-class count equality, safe
# because the rewrite is value-preserving by construction and the replay is
# deterministic.
#
# Assertions (see README.md):
#   B0     die-guard: the untransformed degraded slice analyzes with > 0
#          traces (astronomy R1 already gates this corpus; a broken baseline
#          here is infra, not a semconv finding)
#   G1-G3  die-guards, not assertions: each variant actually carries the
#          intended key population (new-only has zero legacy keys, old-only
#          zero stable keys, dup equal counts per pair), and the fixture does
#          not carry the third dd-trace legacy alias db.type - equality would
#          be vacuously true on a no-op transform
#   D1     old-only variant: identical findings to baseline
#   D2     new-only variant: identical findings to baseline (the headline:
#          the corpus shape the lab never fed before)
#   D3     dup variant: identical findings to baseline
set -uo pipefail

SCENARIO="semconv-drift"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
FIXTURES="${SCRIPT_DIR}/../astronomy-shop/fixtures"
DEGRADED="${FIXTURES}/degraded-slice.ndjson"

OLD_KEYS="db.statement db.system http.method http.url"
NEW_KEYS="db.query.text db.system.name http.request.method url.full"

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
[ -s "${DEGRADED}" ] || die "missing astronomy-shop fixture ${DEGRADED} - run make capture-astronomy-shop"

run_analyze() {  # $1 = input file, $2 = tag ; json to out-<tag>.json, rc passthrough
  "${PERF_SENTINEL_LOCAL_BIN}" analyze --input "$1" \
    --format json > "${TMP_DIR}/out-$2.json" 2> "${TMP_DIR}/err-$2.txt"
}

traces_analyzed() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["analysis"]["traces_analyzed"])' "${TMP_DIR}/out-$1.json"; }

class_counts() {  # sorted "class=count" pairs ; findings JSON (bare or wrapped)
  python3 -c '
import json, sys
from collections import Counter
d = json.load(open(sys.argv[1]))
items = d if isinstance(d, list) else d.get("findings", [])
def u(it): return it.get("finding", it) if isinstance(it, dict) else {}
c = Counter(u(it).get("type", "") for it in items)
c.pop("", None)
print(" ".join(f"{k}={v}" for k, v in sorted(c.items())))' "${TMP_DIR}/out-$1.json"
}

events_processed() {  # informational only - localizes a failure to ingest vs detection
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("analysis",{}).get("events_processed","n/a"))' "${TMP_DIR}/out-$1.json"
}

# Count key OCCURRENCES, not matching lines: the corpus is one minified
# ExportTraceServiceRequest per line holding many spans, so `grep -c`
# (lines) would let a partial dup transform pass the G3 equal-count guard.
keycount() { grep -o "\"key\":\"$2\"" "$1" 2>/dev/null | wc -l | tr -d ' '; }

# ── B0: baseline (die-guard) ────────────────────────────────────────────────
step "B0: analyze the untransformed degraded slice (in-run baseline)"
grep -q '"key":"db.type"' "${DEGRADED}" \
  && die "fixture now carries db.type (the third dd-trace legacy alias) - extend drift.py's PAIRS table deliberately before trusting this gate"
run_analyze "${DEGRADED}" base || die "analyze failed on the untransformed degraded slice: $(tail -2 "${TMP_DIR}/err-base.txt")"
BASE_TA="$(traces_analyzed base)"
BASE_COUNTS="$(class_counts base)"
[ "${BASE_TA}" -gt 0 ] || die "baseline analyzed zero traces"
# D1-D3 assert equality against BASE_COUNTS. A zero-finding baseline makes
# every check compare ""=="" and pass vacuously, so floor the baseline here.
[ -n "${BASE_COUNTS}" ] || die "baseline produced zero findings - the equality gate would be vacuous (fixture or detector regression)"
ok "baseline: traces_analyzed=${BASE_TA}, findings [${BASE_COUNTS:-none}], events=$(events_processed base)"

# ── generate + G1-G3 vacuity die-guards ─────────────────────────────────────
step "generate the three variants + guard their key populations"
for m in old-only new-only dup; do
  python3 "${SCRIPT_DIR}/drift.py" "${m}" "${DEGRADED}" "${TMP_DIR}/${m}.ndjson" \
    > "${TMP_DIR}/${m}.stats" || die "drift.py ${m} failed"
  ok "${m}: $(tr '\n' ' ' < "${TMP_DIR}/${m}.stats")"
done

# G1: new-only carries no legacy key and every stable key
for k in ${OLD_KEYS}; do
  [ "$(keycount "${TMP_DIR}/new-only.ndjson" "${k}")" -eq 0 ] || die "G1: new-only still carries ${k}"
done
for k in ${NEW_KEYS}; do
  [ "$(keycount "${TMP_DIR}/new-only.ndjson" "${k}")" -gt 0 ] || die "G1: new-only carries no ${k} - transform is a no-op"
done
ok "G1: new-only is pure stable semconv"

# G2: old-only carries no stable key and every legacy key
for k in ${NEW_KEYS}; do
  [ "$(keycount "${TMP_DIR}/old-only.ndjson" "${k}")" -eq 0 ] || die "G2: old-only still carries ${k}"
done
for k in ${OLD_KEYS}; do
  [ "$(keycount "${TMP_DIR}/old-only.ndjson" "${k}")" -gt 0 ] || die "G2: old-only carries no ${k} - transform is a no-op"
done
ok "G2: old-only is pure legacy semconv"

# G3: dup carries both keys of each pair in equal numbers, at least the
# fixture's own maximum for the pair
G3_PAIRS="db.statement:db.query.text db.system:db.system.name http.method:http.request.method http.url:url.full"
for pair in ${G3_PAIRS}; do
  o="${pair%%:*}"; n="${pair#*:}"
  CO="$(keycount "${TMP_DIR}/dup.ndjson" "${o}")"
  CN="$(keycount "${TMP_DIR}/dup.ndjson" "${n}")"
  FO="$(keycount "${DEGRADED}" "${o}")"
  FN="$(keycount "${DEGRADED}" "${n}")"
  MAX=$(( FO > FN ? FO : FN ))
  { [ "${CO}" -eq "${CN}" ] && [ "${CO}" -ge "${MAX}" ]; } \
    || die "G3: dup pair ${o}/${n} counts ${CO}/${CN} (fixture max ${MAX}) - twins not duplicated"
done
ok "G3: dup carries both generations of every pair"

# ── D1-D3: identical findings on every variant ──────────────────────────────
for entry in D1:old-only D2:new-only D3:dup; do
  id="${entry%%:*}"; m="${entry#*:}"
  step "${id}: ${m} variant yields findings identical to baseline"
  if run_analyze "${TMP_DIR}/${m}.ndjson" "${m}"; then
    TA="$(traces_analyzed "${m}" 2>/dev/null || echo '?')"
    COUNTS="$(class_counts "${m}" 2>/dev/null)"
    if [ "${TA}" = "${BASE_TA}" ] && [ "${COUNTS}" = "${BASE_COUNTS}" ]; then
      assert_pass "${id}" "${m}: traces_analyzed=${TA}, findings [${COUNTS:-none}] == baseline (events=$(events_processed "${m}"))"
    else
      assert_fail "${id}" "${m}: traces=${TA} vs ${BASE_TA}, findings [${COUNTS:-none}] vs baseline [${BASE_COUNTS:-none}] (events=$(events_processed "${m}" 2>/dev/null || echo '?') vs $(events_processed base))"
    fi
  else
    assert_fail "${id}" "analyze exited non-zero on ${m}: $(tail -2 "${TMP_DIR}/err-${m}.txt")"
  fi
done

# =============================================================================
verdict=$([ "${FAILS}" -eq 0 ] && echo PASS || echo FAIL)
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "perf-sentinel vs the OTel semantic-convention migration: the degraded"
  echo "astronomy-shop slice rewritten to pure-legacy, pure-stable and dual-key"
  echo "corpora must yield findings identical to the untransformed baseline."
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
