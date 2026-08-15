#!/usr/bin/env bash
# verify-hash CLI contract regression scenario (v0.7.0+).
#
# Locks the breaking change shipped in v0.7.0 that made identity flags
# required by default and redesigned the exit-code mapping:
#
#   0 = TRUSTED    (content hash OK and signature OK)
#   1 = UNTRUSTED  (a check actively failed: hash mismatch, identity rejected, etc.)
#   2 = PARTIAL    (no hard failure but a check could not complete)
#   3 = INPUT_ERROR  (bad args, file unreadable, JSON invalid)
#   4 = NETWORK_ERROR (--url mode only: non-HTTPS scheme, fetch error, body cap)
#
# 5 sub-tests against the upstream G2 example fixture
# (`docs/schemas/examples/example-official-public-G2.json`, committed under
# `fixtures/` for hermeticity):
#
#   1. UNTRUSTED on placeholder hash. The shipped example carries a zeroed
#      `integrity.content_hash` placeholder so recompute mismatches. Locks
#      the exit-1 mapping and the `[FAIL] Content hash` stdout marker.
#
#   2. INPUT_ERROR on missing report. Locks exit 3 distinct from exit 1, so
#      a wrapper script reacts differently to a wrong path than to tamper.
#
#   3. NETWORK_ERROR on `--url http://...`. HTTPS-only hardening. Locks
#      exit 4 distinct from exit 3.
#
#   4. UNTRUSTED with the v0.7.0 identity-required error when the report
#      carries `integrity.signature` metadata and the caller passes no
#      `--expected-identity` / `--expected-issuer` and no
#      `--no-identity-check`. The error message is grep-stable:
#      "cannot verify without expected identity".
#
#   5. UNTRUSTED with the half-pair rejection error when only one of
#      `--expected-identity` / `--expected-issuer` is passed. Message:
#      "both --expected-identity and --expected-issuer must be passed
#      together".
#
# Sub-tests 4 and 5 inject a synthetic `integrity.signature` block via jq;
# the cosign delegation never runs because identity validation fails first.
# Coverage gaps NOT addressed here (require a baked-hash fixture):
#   - exit 0 TRUSTED end-to-end roundtrip
#   - exit 2 PARTIAL on hash-valid + signature-absent
# Both require recomputing the canonical content hash, which is an
# in-process Rust call (`compute_content_hash`) without a CLI surface.
# Tracked as follow-up. A `hash-bake` CLI helper would unlock them.

set -euo pipefail

SCENARIO="verify-hash-roundtrip"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="${SCENARIO_DIR}/fixtures/example-official-public-G2.json"

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

step "0. Pre-flight"

command -v docker >/dev/null || die "docker not on PATH"
command -v jq     >/dev/null || die "jq not on PATH"
[ -f "${FIXTURE}" ] || die "fixture missing: ${FIXTURE}"
docker image inspect "${IMAGE}" >/dev/null 2>&1 \
  || docker pull "${IMAGE}" >/dev/null 2>&1 \
  || die "cannot pull ${IMAGE}"
ok "fixture + image OK (${IMAGE})"

# Stage fixture and signed variant in TMP_DIR for container mounts.
cp "${FIXTURE}" "${TMP_DIR}/g2.json"
jq '.integrity.signature = {
      format: "sigstore-cosign-intoto-v1",
      bundle_url: "https://example.com/bundle.json",
      signer_identity: "ci@example.com",
      signer_issuer: "https://accounts.google.com",
      rekor_url: "https://rekor.sigstore.dev",
      rekor_log_index: 12345,
      signed_at: "2026-04-30T12:00:00Z"
    }' "${TMP_DIR}/g2.json" > "${TMP_DIR}/g2-signed.json"

# Helper: run verify-hash in container, capture exit + combined output.
# Sets globals `RUN_EXIT` and `RUN_OUT` for the caller to assert against.
RUN_EXIT=
RUN_OUT=
run_verify() {
  local out
  set +e
  out=$(docker run --rm "${DOCKER_NET_FLAGS[@]}" \
        -u "$(id -u):$(id -g)" \
        -v "${TMP_DIR}:/workdir" \
        "${IMAGE}" verify-hash "$@" 2>&1)
  RUN_EXIT=$?
  set -e
  RUN_OUT="${out}"
}

# Sibling helper for hash-bake. Same shape.
run_bake() {
  local out
  set +e
  out=$(docker run --rm "${DOCKER_NET_FLAGS[@]}" \
        -u "$(id -u):$(id -g)" \
        -v "${TMP_DIR}:/workdir" \
        "${IMAGE}" hash-bake "$@" 2>&1)
  RUN_EXIT=$?
  set -e
  RUN_OUT="${out}"
}

# Tracks per-sub-test verdicts for the final report.
declare -a SUBTEST_NAMES=()
declare -a SUBTEST_VERDICTS=()
declare -a SUBTEST_NOTES=()
record() {
  SUBTEST_NAMES+=("$1")
  SUBTEST_VERDICTS+=("$2")
  SUBTEST_NOTES+=("$3")
}

step "1. Placeholder hash detection (exit 1, [FAIL] Content hash)"
run_verify --report /workdir/g2.json
if [ "${RUN_EXIT}" -eq 1 ] && [[ "${RUN_OUT}" == *"[FAIL] Content hash"* ]]; then
  ok "exit=1, content hash FAIL captured"
  record "1. placeholder hash" PASS "exit=1, '[FAIL] Content hash' present"
else
  fail "expected exit=1 + content hash FAIL; got exit=${RUN_EXIT}"
  record "1. placeholder hash" FAIL "exit=${RUN_EXIT}, output snippet: $(echo "${RUN_OUT}" | head -1)"
fi

step "2. Missing report INPUT_ERROR (exit 3)"
run_verify --report /workdir/does-not-exist.json
if [ "${RUN_EXIT}" -eq 3 ]; then
  ok "exit=3 on missing path"
  record "2. missing report" PASS "exit=3"
else
  fail "expected exit=3; got exit=${RUN_EXIT}"
  record "2. missing report" FAIL "exit=${RUN_EXIT}"
fi

# === Sub-test 3: --url http:// -> NETWORK_ERROR, exit 4 ===
step "3. HTTPS-only hardening (exit 4 on http:// scheme)"
run_verify --url http://example.fr/report.json
if [ "${RUN_EXIT}" -eq 4 ]; then
  ok "exit=4 on http:// scheme"
  record "3. http url rejected" PASS "exit=4"
else
  fail "expected exit=4; got exit=${RUN_EXIT}"
  record "3. http url rejected" FAIL "exit=${RUN_EXIT}"
fi

# === Sub-test 4: signature present + no identity flags -> UNTRUSTED, breaking-change message ===
step "4. Identity-required default (exit 1 + 'cannot verify without expected identity')"
run_verify --report /workdir/g2-signed.json
if [ "${RUN_EXIT}" -eq 1 ] && [[ "${RUN_OUT}" == *"cannot verify without expected identity"* ]]; then
  ok "exit=1, breaking-change message present"
  record "4. identity flags required" PASS "exit=1, breaking-change string present"
else
  fail "expected exit=1 + 'cannot verify without expected identity'; got exit=${RUN_EXIT}"
  record "4. identity flags required" FAIL "exit=${RUN_EXIT}, snippet: $(echo "${RUN_OUT}" | grep -i identity | head -1 || echo none)"
fi

# === Sub-test 5: half-pair identity flag -> UNTRUSTED, half-pair message ===
step "5. Half-pair identity rejection (exit 1 + 'must be passed together')"
run_verify --report /workdir/g2-signed.json --expected-identity ci@example.com
if [ "${RUN_EXIT}" -eq 1 ] && [[ "${RUN_OUT}" == *"must be passed together"* ]]; then
  ok "exit=1, half-pair rejection message present"
  record "5. half-pair rejection" PASS "exit=1, half-pair string present"
else
  fail "expected exit=1 + 'must be passed together'; got exit=${RUN_EXIT}"
  record "5. half-pair rejection" FAIL "exit=${RUN_EXIT}, snippet: $(echo "${RUN_OUT}" | grep -i together | head -1 || echo none)"
fi

step "6. hash-bake roundtrip on unsigned report (verify-hash exit 2 PARTIAL)"
run_bake --report /workdir/g2.json --output /workdir/baked-g2.json
if [ "${RUN_EXIT}" -ne 0 ]; then
  fail "hash-bake failed unexpectedly; exit=${RUN_EXIT}"
  record "6. hash-bake + verify PARTIAL" FAIL "hash-bake exit=${RUN_EXIT}, snippet: $(echo "${RUN_OUT}" | head -1)"
else
  run_verify --report /workdir/baked-g2.json
  if [ "${RUN_EXIT}" -eq 2 ] && [[ "${RUN_OUT}" == *"[OK] Content hash"* ]] && [[ "${RUN_OUT}" == *"PARTIAL"* ]]; then
    ok "verify-hash exit=2, content hash OK, signature NotProvided"
    record "6. hash-bake + verify PARTIAL" PASS "verify-hash exit=2 PARTIAL after bake"
  else
    fail "expected verify exit=2 PARTIAL; got exit=${RUN_EXIT}"
    record "6. hash-bake + verify PARTIAL" FAIL "verify exit=${RUN_EXIT}, snippet: $(echo "${RUN_OUT}" | grep -iE 'partial|hash' | head -1 || echo none)"
  fi
fi

step "7. hash-bake refuses signed report without --allow-signed (exit 1), accepts with flag (exit 0)"
run_bake --report /workdir/g2-signed.json --output /workdir/baked-signed.json
if [ "${RUN_EXIT}" -ne 1 ]; then
  fail "hash-bake should refuse signed report by default; got exit=${RUN_EXIT}"
  record "7. hash-bake refuses signed" FAIL "no-flag exit=${RUN_EXIT}, snippet: $(echo "${RUN_OUT}" | head -1)"
else
  run_bake --report /workdir/g2-signed.json --output /workdir/baked-signed.json --allow-signed
  if [ "${RUN_EXIT}" -eq 0 ]; then
    ok "default refusal exit=1, --allow-signed exit=0"
    record "7. hash-bake refuses signed" PASS "default exit=1, --allow-signed exit=0"
  else
    fail "expected exit=0 with --allow-signed; got exit=${RUN_EXIT}"
    record "7. hash-bake refuses signed" FAIL "--allow-signed exit=${RUN_EXIT}, snippet: $(echo "${RUN_OUT}" | head -1)"
  fi
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
  echo "Fixture: example-official-public-G2.json (committed copy)"
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
  echo
  echo "## Known coverage gaps"
  echo "- exit 0 TRUSTED roundtrip: requires real cosign-signed bundle + matching identity"
  echo "- exit 2 PARTIAL: covered by sub-test 6 (hash-bake + verify-hash)"
} > "${REPORT}"

if [ "${overall}" = "PASS" ]; then
  ok "PASS 7/7, see ${REPORT}"
  exit 0
else
  fail "see ${REPORT}"
  exit 1
fi
