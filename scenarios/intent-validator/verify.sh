#!/usr/bin/env bash
# disclose-time validator regression scenario (v0.7.0+).
#
# Locks the v0.7.0 official-intent disclosure gates:
#   - period_coverage 75% threshold (rejects intent=official when less
#     than 75% of windows carry runtime-calibrated energy)
#   - org-config required-field validation (organisation.country and
#     friends must be present for intent=official)
#
# 4 sub-tests run inside the perf-sentinel image under validation
# (defaults to the lab's currently-pinned version):
#
#   1. internal+internal happy path: complete org-config + above-coverage
#      archive. Disclose succeeds (G1 produced).
#   2. official+public above gate: complete org-config + above-coverage
#      (period_coverage = 1.0). Disclose succeeds (G2 produced).
#   3. official+public below gate: complete org-config + below-coverage
#      archive (period_coverage = 0.25). Disclose fails with stderr
#      matching `is below the 75% threshold`.
#   4. official+public incomplete org-config: above-coverage archive +
#      org-config missing organisation.country. Disclose fails with
#      stderr matching `missing field` and `country`.
#
# Fixtures under fixtures/:
#   - org-config-complete.toml      all required fields populated
#   - org-config-incomplete.toml    missing organisation.country
#   - reports-above-coverage.ndjson 4 runtime windows (energy_kwh>0)
#   - reports-below-coverage.ndjson 1 runtime + 3 fallback windows

set -euo pipefail

SCENARIO="intent-validator"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES_DIR="${SCENARIO_DIR}/fixtures"

# The image under validation, resolved by scripts/resolve-image.sh:
# PERF_SENTINEL_IMAGE, then PERF_SENTINEL_VERSION, then the daemon manifest pin.
# It used to default to a hardcoded old tag, which meant the gate could report a
# PASS for a version this scenario had never executed.
LAB_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../scripts/resolve-image.sh
. "${LAB_ROOT}/scripts/resolve-image.sh"

mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
fail() { color_red   "    fail: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

if [ "$(uname -s)" = "Linux" ]; then
  DOCKER_NET_FLAGS=(--network host)
else
  DOCKER_NET_FLAGS=(--add-host=host.docker.internal:host-gateway)
fi

# === Pre-flight ===
step "0. Pre-flight"

command -v docker >/dev/null || die "docker not on PATH"
[ -f "${FIXTURES_DIR}/org-config-complete.toml" ] || die "fixture missing: org-config-complete.toml"
[ -f "${FIXTURES_DIR}/org-config-incomplete.toml" ] || die "fixture missing: org-config-incomplete.toml"
[ -f "${FIXTURES_DIR}/reports-above-coverage.ndjson" ] || die "fixture missing: reports-above-coverage.ndjson"
[ -f "${FIXTURES_DIR}/reports-below-coverage.ndjson" ] || die "fixture missing: reports-below-coverage.ndjson"
docker image inspect "${IMAGE}" >/dev/null 2>&1 \
  || docker pull "${IMAGE}" >/dev/null 2>&1 \
  || die "cannot pull ${IMAGE}"
ok "fixtures + image OK (${IMAGE})"

# Stage fixtures into TMP_DIR for container mounts.
cp "${FIXTURES_DIR}/org-config-complete.toml"      "${TMP_DIR}/org-config-complete.toml"
cp "${FIXTURES_DIR}/org-config-incomplete.toml"    "${TMP_DIR}/org-config-incomplete.toml"
cp "${FIXTURES_DIR}/reports-above-coverage.ndjson" "${TMP_DIR}/above.ndjson"
cp "${FIXTURES_DIR}/reports-below-coverage.ndjson" "${TMP_DIR}/below.ndjson"

# Helper: run disclose in container, capture exit + combined output.
RUN_EXIT=
RUN_OUT=
run_disclose() {
  local out
  set +e
  out=$(docker run --rm "${DOCKER_NET_FLAGS[@]}" \
        -u "$(id -u):$(id -g)" \
        -v "${TMP_DIR}:/workdir" \
        "${IMAGE}" disclose "$@" 2>&1)
  RUN_EXIT=$?
  set -e
  RUN_OUT="${out}"
}

declare -a SUBTEST_NAMES=()
declare -a SUBTEST_VERDICTS=()
declare -a SUBTEST_NOTES=()
record() {
  SUBTEST_NAMES+=("$1")
  SUBTEST_VERDICTS+=("$2")
  SUBTEST_NOTES+=("$3")
}

PERIOD_ARGS=(--period-type calendar-quarter --from 2026-01-01 --to 2026-03-31)

# Align the declared SPECpower vintage with the binary's own, DERIVED rather
# than hardcoded. The official-intent validator requires the two to be equal,
# and the embedded table is refreshed from upstream coefficients every so often,
# so a committed literal expires silently: the scenario then fails on a stale
# fixture and reads as a product defect. The committed file keeps a documentary
# value; this run overwrites the staged copy.
#
# `disclose --intent internal` does not run the official validator, so it is a
# safe way to read `binary_specpower_vintage` back out of a report. Only its
# first whitespace-delimited token is the declarable date: the binary annotates
# it (e.g. "2026-04-24 (CCF aligned)") and the validator compares that prefix.
step "0b. Align the declared SPECpower vintage with the binary's"
run_disclose --intent internal --confidentiality internal "${PERIOD_ARGS[@]}" \
  --input /workdir/above.ndjson \
  --output /workdir/vintage-probe.json \
  --org-config /workdir/org-config-complete.toml
BINARY_VINTAGE="$(python3 -c "
import json, sys
try:
    ci = json.load(open('${TMP_DIR}/vintage-probe.json'))['methodology']['calibration_inputs']
    print((ci.get('binary_specpower_vintage') or '').split()[0])
except Exception:
    print('')" 2>/dev/null)"
if [ -n "${BINARY_VINTAGE}" ]; then
  python3 - "${TMP_DIR}/org-config-complete.toml" "${BINARY_VINTAGE}" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
p.write_text(re.sub(r'(?m)^specpower_table_version\s*=.*$',
                    f'specpower_table_version = "{sys.argv[2]}"', p.read_text()))
PY
  ok "declared vintage aligned on the binary: ${BINARY_VINTAGE}"
else
  fail "could not read binary_specpower_vintage; sub-test 2 will report whatever the committed literal gives"
fi

# === Sub-test 1: internal+internal happy path ===
step "1. internal+internal ABOVE complete (G1 produced)"
rm -f "${TMP_DIR}/t1-output.json"
run_disclose --intent internal --confidentiality internal "${PERIOD_ARGS[@]}" \
  --input /workdir/above.ndjson \
  --output /workdir/t1-output.json \
  --org-config /workdir/org-config-complete.toml
if [ "${RUN_EXIT}" -eq 0 ] && [ -f "${TMP_DIR}/t1-output.json" ]; then
  ok "exit=0, output file written"
  record "1. internal G1 happy path" PASS "exit=0, t1-output.json present"
else
  fail "expected exit=0 + output; got exit=${RUN_EXIT}"
  record "1. internal G1 happy path" FAIL "exit=${RUN_EXIT}, output exists: $([ -f "${TMP_DIR}/t1-output.json" ] && echo yes || echo no)"
fi

# === Sub-test 2: official+public above gate ===
step "2. official+public ABOVE complete (G2 produced)"
rm -f "${TMP_DIR}/t2-output.json"
run_disclose --intent official --confidentiality public "${PERIOD_ARGS[@]}" \
  --input /workdir/above.ndjson \
  --output /workdir/t2-output.json \
  --org-config /workdir/org-config-complete.toml
if [ "${RUN_EXIT}" -eq 0 ] && [ -f "${TMP_DIR}/t2-output.json" ]; then
  ok "exit=0, output file written"
  record "2. official G2 happy path" PASS "exit=0, t2-output.json present"
else
  fail "expected exit=0 + output; got exit=${RUN_EXIT}"
  record "2. official G2 happy path" FAIL "exit=${RUN_EXIT}, output exists: $([ -f "${TMP_DIR}/t2-output.json" ] && echo yes || echo no)"
fi

# === Sub-test 3: official+public below gate ===
step "3. official+public BELOW complete (75% gate triggers, non-zero exit)"
rm -f "${TMP_DIR}/t3-output.json"
run_disclose --intent official --confidentiality public "${PERIOD_ARGS[@]}" \
  --input /workdir/below.ndjson \
  --output /workdir/t3-output.json \
  --org-config /workdir/org-config-complete.toml
if [ "${RUN_EXIT}" -ne 0 ] && [[ "${RUN_OUT}" == *"is below the 75% threshold"* ]]; then
  ok "exit=${RUN_EXIT}, 75% gate error string present"
  record "3. period_coverage gate" PASS "exit=${RUN_EXIT}, '75% threshold' present"
else
  fail "expected non-zero exit + '75% threshold' string; got exit=${RUN_EXIT}"
  record "3. period_coverage gate" FAIL "exit=${RUN_EXIT}, snippet: $(echo "${RUN_OUT}" | grep -i threshold | head -1 || echo none)"
fi

# === Sub-test 4: official+public incomplete org-config ===
step "4. official+public ABOVE incomplete (org-config required field, non-zero exit)"
rm -f "${TMP_DIR}/t4-output.json"
run_disclose --intent official --confidentiality public "${PERIOD_ARGS[@]}" \
  --input /workdir/above.ndjson \
  --output /workdir/t4-output.json \
  --org-config /workdir/org-config-incomplete.toml
if [ "${RUN_EXIT}" -ne 0 ] && [[ "${RUN_OUT}" == *"missing field"* ]] && [[ "${RUN_OUT}" == *"country"* ]]; then
  ok "exit=${RUN_EXIT}, org-config required-field error present"
  record "4. org-config required field" PASS "exit=${RUN_EXIT}, 'missing field' + 'country' present"
else
  fail "expected non-zero exit + 'missing field' + 'country'; got exit=${RUN_EXIT}"
  record "4. org-config required field" FAIL "exit=${RUN_EXIT}, snippet: $(echo "${RUN_OUT}" | grep -iE 'missing|country' | head -1 || echo none)"
fi

# === Aggregate verdict + report ===
overall="PASS"
for v in "${SUBTEST_VERDICTS[@]}"; do
  [ "${v}" = "FAIL" ] && overall="FAIL"
done

{
  echo "# Scenario: ${SCENARIO}"
  echo
  echo "Image: ${IMAGE}"
  echo "Fixtures: scenarios/${SCENARIO}/fixtures/"
  echo
  echo "## Sub-tests"
  echo
  echo "| # | Name | Verdict | Note |"
  echo "| --- | --- | --- | --- |"
  for i in "${!SUBTEST_NAMES[@]}"; do
    echo "| $((i+1)) | ${SUBTEST_NAMES[$i]} | ${SUBTEST_VERDICTS[$i]} | ${SUBTEST_NOTES[$i]} |"
  done
  echo
  echo "## Verdict: ${overall}"
} > "${REPORT}"

if [ "${overall}" = "PASS" ]; then
  ok "PASS 4/4, see ${REPORT}"
  exit 0
else
  fail "see ${REPORT}"
  exit 1
fi
