#!/usr/bin/env bash
# RGESN 2024 crosswalk on disclosed anti-patterns (perf-sentinel 0.8.13, gate G2).
#
# 0.8.13 maps each detector to RGESN criteria and surfaces them on
# `applications[].anti_patterns[].rgesn_criteria` in an internal disclosure
# (--confidentiality internal = per-anti-pattern detail). slow_sql / slow_http
# carry no criteria and the field is OMITTED from the wire.
#
# Self-contained: `analyze` a committed multi-pattern trace fixture
# (artifacts/fixtures/em-real-time-traces.json -> yields n_plus_one_sql,
# n_plus_one_http, redundant_sql/http, chatty_service, excessive_fanout,
# serialized_calls, slow_http), wrap the report as a single archived window,
# then `disclose --intent internal`. No daemon/cluster contact. Reuses the
# committed disclose org-config (scenarios/disclose/fixtures/org-config.toml).
#
# Image: the version under validation (see scripts/resolve-image.sh); for an
# unpublished pre-release, build it locally and pass PERF_SENTINEL_IMAGE.

set -euo pipefail

SCENARIO="rgesn-crosswalk"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"

# The image under validation, resolved by scripts/resolve-image.sh:
# PERF_SENTINEL_IMAGE, then PERF_SENTINEL_VERSION, then the daemon manifest pin.
# It used to default to a hardcoded old tag, which meant the gate could report a
# PASS for a version this scenario had never executed.
LAB_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../scripts/resolve-image.sh
. "${LAB_ROOT}/scripts/resolve-image.sh"
TRACES="${REPO_ROOT}/artifacts/fixtures/em-real-time-traces.json"
ORG_CONFIG="${REPO_ROOT}/scenarios/disclose/fixtures/org-config.toml"

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

EXPECTED='{
  "n_plus_one_sql":   ["7.1","6.1"],
  "n_plus_one_http":  ["7.1","6.1"],
  "redundant_sql":    ["7.1","6.5"],
  "redundant_http":   ["7.1","6.5"],
  "chatty_service":   ["4.9","4.10","6.1"],
  "excessive_fanout": ["3.2"],
  "pool_saturation":  ["3.2"],
  "serialized_calls": ["8.10"]
}'

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

# === 1. analyze -> window -> disclose internal ===
step "1. analyze -> archived window -> disclose --intent internal"
in_image analyze --input /workdir/traces.json --format json > "${TMP_DIR}/analyze.json" 2>/dev/null \
  || die "analyze failed"
jq -c '{report: ., ts: "2026-05-15T12:00:00Z"}' "${TMP_DIR}/analyze.json" > "${TMP_DIR}/windows.ndjson"
in_image disclose --intent internal --confidentiality internal \
  --period-type calendar-quarter --from 2026-04-01 --to 2026-06-30 \
  --input /workdir/windows.ndjson --output /workdir/report.json \
  --org-config /workdir/org-config.toml > "${TMP_DIR}/disclose.log" 2>&1 || { cat "${TMP_DIR}/disclose.log"; die "disclose failed"; }
AP_COUNT="$(jq '[.applications[].anti_patterns[]?] | length' "${TMP_DIR}/report.json")"
[ "${AP_COUNT}" -ge 1 ] || die "disclose produced no anti_patterns"
ok "disclose produced ${AP_COUNT} anti_patterns across $(jq '.applications|length' "${TMP_DIR}/report.json") services"

# === 2. mapping correct on every present anti-pattern ===
step "2. rgesn_criteria matches the 0.8.13 mapping"
MAP_OK="$(jq --argjson exp "${EXPECTED}" '
  [.applications[].anti_patterns[]?]
  | map(.type as $t |
      if ($t|test("^slow_")) then true
      else (.rgesn_criteria == $exp[$t]) end)
  | all' "${TMP_DIR}/report.json")"
PRESENT="$(jq -r '[.applications[].anti_patterns[]?.type] | unique | join(",")' "${TMP_DIR}/report.json")"
if [ "${MAP_OK}" = "true" ]; then ok "mapping correct for: ${PRESENT}"; record "mapping" "PASS" "${PRESENT}"
else
  fail "mapping mismatch; observed:"; jq -c '[.applications[].anti_patterns[]? | {type, rgesn_criteria}] | unique' "${TMP_DIR}/report.json"
  record "mapping" "FAIL" "see log"
fi

# === 3. slow_* omitted from the wire ===
step "3. slow_sql / slow_http carry no rgesn_criteria field"
SLOW_PRESENT="$(jq '[.applications[].anti_patterns[]? | select(.type|test("^slow_"))] | length' "${TMP_DIR}/report.json")"
SLOW_LEAK="$(jq '[.applications[].anti_patterns[]? | select(.type|test("^slow_")) | select(has("rgesn_criteria"))] | length' "${TMP_DIR}/report.json")"
if [ "${SLOW_PRESENT}" -ge 1 ] && [ "${SLOW_LEAK}" -eq 0 ]; then
  ok "${SLOW_PRESENT} slow_* anti-pattern(s) present, none carry rgesn_criteria"
  record "slow-omitted" "PASS" "${SLOW_PRESENT} slow_* present, field absent"
elif [ "${SLOW_PRESENT}" -eq 0 ]; then
  fail "no slow_* anti-pattern present to prove omission (fixture drift)"
  record "slow-omitted" "FAIL" "no slow_* in output"
else
  fail "${SLOW_LEAK} slow_* anti-pattern(s) leaked rgesn_criteria"
  record "slow-omitted" "FAIL" "${SLOW_LEAK} leaked"
fi

# === Summary ===
step "Summary"
pass=0; failc=0; skip=0
{ echo "# ${SCENARIO}"; echo; } > "${REPORT}"
for i in "${!NAMES[@]}"; do
  printf "  %-14s %-5s %s\n" "${NAMES[$i]}" "${VERDICTS[$i]}" "${NOTES[$i]}"
  printf -- "- **%s**: %s — %s\n" "${NAMES[$i]}" "${VERDICTS[$i]}" "${NOTES[$i]}" >> "${REPORT}"
  case "${VERDICTS[$i]}" in PASS) pass=$((pass+1));; FAIL) failc=$((failc+1));; SKIP) skip=$((skip+1));; esac
done
echo "  --- ${pass} PASS / ${failc} FAIL / ${skip} SKIP ---"
[ "$failc" -eq 0 ] || exit 1
