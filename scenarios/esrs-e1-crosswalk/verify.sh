#!/usr/bin/env bash
# ESRS E1 crosswalk + schema floor + hash integrity (perf-sentinel 0.8.13, gate R1).
#
# 0.8.13 bumps the disclosure wire schema to perf-sentinel-report/v1.3 and adds
# `methodology.standard_crosswalk` (an ESRS E1 datapoint mapping aid) plus the
# matching disclaimer. This scenario disclosing an internal report and asserts:
#   1. schema_version >= perf-sentinel-report/v1.3 (a floor: the schema is
#      additive, so a later version must still satisfy this leg)
#   2. standard_crosswalk: standard ~ "ESRS E1", datapoints reference
#      E1-5 / Scope 2 / Scope 3, a note/caveat mentions market-based
#   3. notes.disclaimers carries the ESRS standard_crosswalk mapping-aid line
#   4. integrity: hash-bake -> verify-hash = PARTIAL/exit 2 + [OK] Content hash
#      (unsigned); a tampered byte -> [FAIL] Content hash / exit 1
#   5. retro-compat: a frozen v1.2 example still validates against the v1.3
#      JSON Schema (docs/schemas/perf-sentinel-report-v1.json in the product repo)
#
# Self-contained (analyze -> archived window -> disclose, no daemon). Reuses the
# committed disclose org-config. The retro-compat check needs check-jsonschema
# and the product repo schema/examples; SKIPped (not failed) if either is absent.
#
# Image: ghcr.io/robintra/perf-sentinel:${PERF_SENTINEL_VERSION:-0.8.13}.

set -euo pipefail

SCENARIO="esrs-e1-crosswalk"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"

PERF_SENTINEL_VERSION="${PERF_SENTINEL_VERSION:-0.8.13}"
IMAGE="ghcr.io/robintra/perf-sentinel:${PERF_SENTINEL_VERSION}"
PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-$HOME/RustroverProjects/perf-sentinel}"
TRACES="${REPO_ROOT}/artifacts/fixtures/em-real-time-traces.json"
ORG_CONFIG="${REPO_ROOT}/scenarios/disclose/fixtures/org-config.toml"
SCHEMA="${PERF_SENTINEL_REPO_PATH}/docs/schemas/perf-sentinel-report-v1.json"

mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
fail() { color_red   "    fail: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

declare -a NAMES=() VERDICTS=() NOTES=()
record() { NAMES+=("$1"); VERDICTS+=("$2"); NOTES+=("$3"); }
in_image() { docker run --rm -u "$(id -u):$(id -g)" -v "${TMP_DIR}:/workdir" "${IMAGE}" "$@"; }

# === Pre-flight ===
step "0. Pre-flight"
command -v docker >/dev/null || die "docker not on PATH"
command -v jq >/dev/null || die "jq not on PATH"
[ -f "${TRACES}" ]     || die "trace fixture missing: ${TRACES}"
[ -f "${ORG_CONFIG}" ] || die "org-config missing: ${ORG_CONFIG}"
docker image inspect "${IMAGE}" >/dev/null 2>&1 || docker pull "${IMAGE}" >/dev/null 2>&1 || die "cannot get ${IMAGE}"
cp "${TRACES}" "${TMP_DIR}/traces.json"
cp "${ORG_CONFIG}" "${TMP_DIR}/org-config.toml"
ok "image + fixtures OK (${IMAGE})"

# === 1. disclose an internal report ===
step "1. analyze -> archived window -> disclose --intent internal"
in_image analyze --input /workdir/traces.json --format json > "${TMP_DIR}/analyze.json" 2>/dev/null || die "analyze failed"
jq -c '{report: ., ts: "2026-05-15T12:00:00Z"}' "${TMP_DIR}/analyze.json" > "${TMP_DIR}/windows.ndjson"
in_image disclose --intent internal --confidentiality internal \
  --period-type calendar-quarter --from 2026-04-01 --to 2026-06-30 \
  --input /workdir/windows.ndjson --output /workdir/report.json \
  --org-config /workdir/org-config.toml > "${TMP_DIR}/disclose.log" 2>&1 || { cat "${TMP_DIR}/disclose.log"; die "disclose failed"; }
ok "disclosed /workdir/report.json"

# === 2. schema floor ===
# A FLOOR, not an equality. The disclosure schema is additive by contract and
# this leg's intent is "at least the version that introduced the crosswalk",
# which is v1.3. Pinning the exact string made the scenario fail the moment the
# product bumped — a lab staleness rather than a product defect, and the same
# correction alumet-db-waste already carries.
step "2. schema_version >= perf-sentinel-report/v1.3"
SV="$(jq -r '.schema_version' "${TMP_DIR}/report.json")"
if python3 -c "
import re, sys
m = re.search(r'/v(\d+)\.(\d+)', '${SV}')
sys.exit(0 if m and (int(m.group(1)), int(m.group(2))) >= (1, 3) else 1)"; then
  ok "${SV} (floor v1.3)"; record "schema-floor" "PASS" "${SV} >= v1.3"
else fail "schema_version=${SV}, below the v1.3 floor"; record "schema-floor" "FAIL" "${SV}"; fi

# === 3. standard_crosswalk ESRS E1 ===
step "3. methodology.standard_crosswalk references ESRS E1 / E1-5 / Scope 2 / Scope 3 / market-based"
CW="$(jq -c '.methodology.standard_crosswalk' "${TMP_DIR}/report.json")"
cw_ok=1
# `strings |` skips any null element (a mapping/caveat missing the field), which
# would otherwise make jq's test() abort (exit 5) and mis-FAIL a valid report.
echo "${CW}" | jq -e '(.standard // "") | test("ESRS E1")' >/dev/null || { fail "standard !~ ESRS E1"; cw_ok=0; }
echo "${CW}" | jq -e '[.mappings[].datapoint] | any(strings | test("E1-5"))'   >/dev/null || { fail "no E1-5 datapoint"; cw_ok=0; }
echo "${CW}" | jq -e '[.mappings[].datapoint] | any(strings | test("Scope 2"))' >/dev/null || { fail "no Scope 2 datapoint"; cw_ok=0; }
echo "${CW}" | jq -e '[.mappings[].datapoint] | any(strings | test("Scope 3"))' >/dev/null || { fail "no Scope 3 datapoint"; cw_ok=0; }
echo "${CW}" | jq -e '([.mappings[].note] + (.caveats // [])) | any(strings | test("market-based"))' >/dev/null || { fail "no market-based note/caveat"; cw_ok=0; }
if [ "${cw_ok}" -eq 1 ]; then ok "ESRS E1 + E1-5 + Scope 2 + Scope 3 + market-based all present"; record "esrs-crosswalk" "PASS" "ESRS E1 / E1-5 / Scope 2 / Scope 3 / market-based"
else record "esrs-crosswalk" "FAIL" "see log"; fi

# === 4. disclaimers ESRS line ===
step "4. notes.disclaimers carries the ESRS mapping-aid line"
# `standard_crosswalk` is unique to the ESRS disclaimer line; matching on it alone
# is robust to null elements and to the wording being split across lines.
if jq -e '[.notes.disclaimers[]?] | any(strings | test("standard_crosswalk"))' "${TMP_DIR}/report.json" >/dev/null; then
  ok "ESRS disclaimer present"; record "esrs-disclaimer" "PASS" "standard_crosswalk mapping aid line"
else fail "ESRS disclaimer missing"; record "esrs-disclaimer" "FAIL" "line absent"; fi

# === 5. integrity: hash-bake -> verify-hash PARTIAL + tamper FAIL ===
step "5. hash-bake -> verify-hash (PARTIAL/exit2 + [OK] Content hash), tamper -> [FAIL]/exit1"
in_image hash-bake --report /workdir/report.json --output /workdir/baked.json >/dev/null 2>&1 || die "hash-bake failed"
set +e
out_ok=$(in_image verify-hash --report /workdir/baked.json 2>&1); code_ok=$?
set -e
jq '.organisation.name = "TAMPERED SAS"' "${TMP_DIR}/baked.json" > "${TMP_DIR}/tampered.json" || die "tamper jq failed"
set +e
out_bad=$(in_image verify-hash --report /workdir/tampered.json 2>&1); code_bad=$?
set -e
int_ok=1
{ [ "${code_ok}" -eq 2 ] && echo "${out_ok}" | grep -q '\[OK\] Content hash'; } || { fail "unsigned: expected exit2 + [OK] Content hash (got exit ${code_ok})"; int_ok=0; }
{ [ "${code_bad}" -eq 1 ] && echo "${out_bad}" | grep -q '\[FAIL\] Content hash'; } || { fail "tampered: expected exit1 + [FAIL] Content hash (got exit ${code_bad})"; int_ok=0; }
if [ "${int_ok}" -eq 1 ]; then ok "unsigned=PARTIAL/exit2 [OK] Content hash; tampered=UNTRUSTED/exit1 [FAIL] Content hash"; record "hash-integrity" "PASS" "PARTIAL + tamper-detected"
else record "hash-integrity" "FAIL" "see log"; fi

# === 6. retro-compat: v1.2 example validates against the v1.3 schema ===
step "6. retro-compat: frozen v1.2 example validates against the v1.3 JSON Schema"
EXAMPLE="${PERF_SENTINEL_REPO_PATH}/docs/schemas/examples/example-internal-G1.json"
if command -v check-jsonschema >/dev/null && [ -f "${SCHEMA}" ] && [ -f "${EXAMPLE}" ]; then
  EX_VER="$(jq -r '.schema_version' "${EXAMPLE}")"
  if check-jsonschema --schemafile "${SCHEMA}" "${EXAMPLE}" >/dev/null 2>&1; then
    ok "${EX_VER} example validates against v1.3 schema"; record "retro-compat" "PASS" "${EX_VER} valid vs v1.3 schema"
  else fail "v1.2 example failed v1.3 schema validation"; record "retro-compat" "FAIL" "validation error"; fi
else
  ok "check-jsonschema or schema/example absent -> SKIP"; record "retro-compat" "SKIP" "validator or fixture missing"
fi

# === Summary ===
step "Summary"
pass=0; failc=0; skip=0
{ echo "# ${SCENARIO}"; echo; } > "${REPORT}"
for i in "${!NAMES[@]}"; do
  printf "  %-16s %-5s %s\n" "${NAMES[$i]}" "${VERDICTS[$i]}" "${NOTES[$i]}"
  printf -- "- **%s**: %s — %s\n" "${NAMES[$i]}" "${VERDICTS[$i]}" "${NOTES[$i]}" >> "${REPORT}"
  case "${VERDICTS[$i]}" in PASS) pass=$((pass+1));; FAIL) failc=$((failc+1));; SKIP) skip=$((skip+1));; esac
done
echo "  --- ${pass} PASS / ${failc} FAIL / ${skip} SKIP ---"
[ "$failc" -eq 0 ] || exit 1
