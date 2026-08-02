#!/usr/bin/env bash
# verify-hash fail-closed on a signed report without identity flags
# (perf-sentinel 0.8.13, gate R2).
#
# A report that carries integrity.signature but is verified WITHOUT
# --expected-identity / --expected-issuer (and without --no-identity-check) must
# fail closed: the identity gate short-circuits BEFORE cosign (so no cosign
# binary is needed), yielding exit 1 / UNTRUSTED with [FAIL] Signature, while the
# content hash still validates ([OK] Content hash, since the canonical hash
# blanks the signature). This guards against a Sigstore bundle forgeable by any
# GitHub/Google account holder.
#
# Self-contained: analyze -> archived window -> disclose -> hash-bake produces a
# valid baked report, then a fake SignatureMetadata block is injected and
# verify-hash is run with no identity flags. No daemon/cluster, no cosign.
#
# Image: the version under validation (see scripts/resolve-image.sh).

set -euo pipefail

SCENARIO="verify-hash-fail-closed"
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

FAKE_SIG='{
  "format": "sigstore-cosign-intoto-v1",
  "bundle_url": "https://example.com/report.bundle.sig",
  "signer_identity": "attacker@example.com",
  "signer_issuer": "https://accounts.google.com",
  "rekor_url": "https://rekor.sigstore.dev",
  "rekor_log_index": 1,
  "signed_at": "2026-05-15T12:00:00Z"
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

# === 1. build a baked report ===
step "1. analyze -> window -> disclose -> hash-bake"
in_image analyze --input /workdir/traces.json --format json > "${TMP_DIR}/analyze.json" 2>/dev/null || die "analyze failed"
jq -c '{report: ., ts: "2026-05-15T12:00:00Z"}' "${TMP_DIR}/analyze.json" > "${TMP_DIR}/windows.ndjson"
in_image disclose --intent internal --confidentiality internal \
  --period-type calendar-quarter --from 2026-04-01 --to 2026-06-30 \
  --input /workdir/windows.ndjson --output /workdir/report.json \
  --org-config /workdir/org-config.toml > "${TMP_DIR}/disclose.log" 2>&1 || { cat "${TMP_DIR}/disclose.log"; die "disclose failed"; }
in_image hash-bake --report /workdir/report.json --output /workdir/baked.json >/dev/null 2>&1 || die "hash-bake failed"
ok "baked report ready"

# === 2. forge a signed report (fake signature, no real bundle) ===
step "2. inject a fake integrity.signature"
jq --argjson sig "${FAKE_SIG}" '.integrity.signature = $sig' "${TMP_DIR}/baked.json" > "${TMP_DIR}/forged.json"
[ "$(jq -r '.integrity.signature.format' "${TMP_DIR}/forged.json")" = "sigstore-cosign-intoto-v1" ] || die "signature injection failed"
ok "signature injected (signer_identity=attacker@example.com)"

# === 3. verify-hash without identity flags -> fail closed ===
step "3. verify-hash (no --expected-identity/--expected-issuer) -> exit1 UNTRUSTED"
set +e
out=$(in_image verify-hash --report /workdir/forged.json 2>&1); code=$?
set -e
echo "${out}" | grep -E 'Content hash|Signature|Overall' || true
r2_ok=1
[ "${code}" -eq 1 ]                              || { fail "expected exit 1, got ${code}"; r2_ok=0; }
echo "${out}" | grep -q '\[FAIL\] Signature'     || { fail "expected [FAIL] Signature"; r2_ok=0; }
echo "${out}" | grep -q '\[OK\] Content hash'    || { fail "expected [OK] Content hash"; r2_ok=0; }
echo "${out}" | grep -q 'Overall: UNTRUSTED'     || { fail "expected Overall: UNTRUSTED"; r2_ok=0; }
if [ "${r2_ok}" -eq 1 ]; then ok "fail-closed: exit1 UNTRUSTED, [FAIL] Signature, [OK] Content hash (no cosign needed)"; record "fail-closed" "PASS" "exit1 UNTRUSTED + [FAIL] Signature + [OK] Content hash"
else record "fail-closed" "FAIL" "see log"; fi

# === Summary ===
step "Summary"
pass=0; failc=0; skip=0
{ echo "# ${SCENARIO}"; echo; } > "${REPORT}"
for i in "${!NAMES[@]}"; do
  printf "  %-12s %-5s %s\n" "${NAMES[$i]}" "${VERDICTS[$i]}" "${NOTES[$i]}"
  printf -- "- **%s**: %s — %s\n" "${NAMES[$i]}" "${VERDICTS[$i]}" "${NOTES[$i]}" >> "${REPORT}"
  case "${VERDICTS[$i]}" in PASS) pass=$((pass+1));; FAIL) failc=$((failc+1));; SKIP) skip=$((skip+1));; esac
done
echo "  --- ${pass} PASS / ${failc} FAIL / ${skip} SKIP ---"
[ "$failc" -eq 0 ] || exit 1
