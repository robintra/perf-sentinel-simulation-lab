#!/usr/bin/env bash
# Periodic-disclosure v1.2 continuity scenario (v0.8.3+, schema v1.2).
#
# Locks the v0.8.3 schema-v1.2 additions that the `disclose` scenario (a 0.8.2 /
# v1.1 contract lock) does not cover: aggregate.temporal_coverage,
# scope_manifest.coverage_basis, the reserved integrity.cross_period_log, the
# dense-vs-sparse continuity signal, and the v1.2 validator rules.
#
# Hermetic CLI scenario (same family as disclose / intent-validator):
# `docker run ...:${PERF_SENTINEL_VERSION} disclose` over committed fixtures, no
# cluster. The two fixtures are fabricated from a real 0.8.3-daemon archive line
# by varying ONLY `ts` (findings trimmed; the tiers/energy live in
# disclosure_waste + green_summary, temporal_coverage is derived from the ts
# dates by the aggregator):
#   - reports-dense.ndjson   one window per UTC day, 30 days  -> coverage 1.0
#   - reports-sparse.ndjson  3 windows (2026-05-08/05-22/06-06) -> coverage 0.1,
#                            largest_gap 14 (missing days in the 05-22..06-06 span)
#
# 5 sub-tests run inside `ghcr.io/robintra/perf-sentinel:${PERF_SENTINEL_VERSION}`
# (defaults to 0.8.3, the version that introduced v1.2):
#
#   1. schema v1.2 + v1.2 fields: schema_version, temporal_coverage (4 subfields),
#      coverage_basis (operator_declared/machine_derived), cross_period_log absent.
#   2. dense continuity: temporal_coverage 1.0, observed==days==30, gap 0, NO
#      "temporal coverage is" warning on stderr, in-band "Temporal coverage" disclaimer.
#   3. sparse continuity: temporal_coverage 0.1 (3/30), gap 14, stderr warning
#      "temporal coverage is 10.0%", in-band disclaimer.
#   4. verify-hash round-trip (the 0.8.2 guard, now with the temporal_coverage
#      float in the canonical hash): content_hash OK on dense + sparse; tampered FAIL.
#   5. v1.2 validator reject: official with total_requests_in_period < requests_measured
#      -> disclose rejects (requests_measured exceeds declared), no file written.
#
# Fixtures under fixtures/: reports-dense.ndjson, reports-sparse.ndjson, org-config.toml
# (org-config specpower_table_version tracks the pinned image's embedded CCF
#  vintage; bump it alongside PERF_SENTINEL_VERSION if the vintage changes.)

set -euo pipefail

SCENARIO="disclose-temporal"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES_DIR="${SCENARIO_DIR}/fixtures"

PERF_SENTINEL_VERSION="${PERF_SENTINEL_VERSION:-0.8.3}"
IMAGE="ghcr.io/robintra/perf-sentinel:${PERF_SENTINEL_VERSION}"

mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
fail() { color_red   "    fail: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

# Frozen to match the frozen fixture `ts` values (2026-05-08 .. 2026-06-06 = 30 days).
PERIOD_ARGS=(--period-type custom --from 2026-05-08 --to 2026-06-06)

# === Pre-flight ===
step "0. Pre-flight"
command -v docker >/dev/null || die "docker not on PATH"
command -v python3 >/dev/null || die "python3 not on PATH"
for f in reports-dense.ndjson reports-sparse.ndjson org-config.toml; do
  [ -f "${FIXTURES_DIR}/${f}" ] || die "fixture missing: ${f}"
done
docker image inspect "${IMAGE}" >/dev/null 2>&1 \
  || docker pull "${IMAGE}" >/dev/null 2>&1 \
  || die "cannot pull ${IMAGE}"
cp "${FIXTURES_DIR}/reports-dense.ndjson"  "${TMP_DIR}/reports-dense.ndjson"
cp "${FIXTURES_DIR}/reports-sparse.ndjson" "${TMP_DIR}/reports-sparse.ndjson"
cp "${FIXTURES_DIR}/org-config.toml"       "${TMP_DIR}/org-config.toml"
# Drop prior-run outputs so a stale file can never satisfy a later check.
rm -f "${TMP_DIR}"/out-*.json "${TMP_DIR}"/*.stderr
ok "fixtures + image OK (${IMAGE})"

# disclose is offline; run as the host user so outputs are writable on the mount.
in_image() {
  docker run --rm -u "$(id -u):$(id -g)" -v "${TMP_DIR}:/workdir" "${IMAGE}" "$@"
}

declare -a NAMES=() VERDICTS=() NOTES=()
record() { NAMES+=("$1"); VERDICTS+=("$2"); NOTES+=("$3"); }

# Produce the dense + sparse disclosures once, capturing stderr for the warning checks.
in_image disclose --intent internal --confidentiality internal "${PERIOD_ARGS[@]}" \
  --input /workdir/reports-dense.ndjson --output /workdir/out-dense.json \
  --org-config /workdir/org-config.toml >/dev/null 2>"${TMP_DIR}/dense.stderr" || true
in_image disclose --intent internal --confidentiality internal "${PERIOD_ARGS[@]}" \
  --input /workdir/reports-sparse.ndjson --output /workdir/out-sparse.json \
  --org-config /workdir/org-config.toml >/dev/null 2>"${TMP_DIR}/sparse.stderr" || true

# === Sub-test 1: schema v1.2 + v1.2 fields (dense) ===
step "1. schema v1.2 + temporal_coverage + coverage_basis + cross_period_log absent"
note=""
if [ -f "${TMP_DIR}/out-dense.json" ] \
   && note="$(python3 - "${TMP_DIR}/out-dense.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
tc = r["aggregate"].get("temporal_coverage")
cb = r["scope_manifest"].get("coverage_basis")
checks = {
    "schema v1.2": r["schema_version"] == "perf-sentinel-report/v1.2",
    "temporal_coverage 4 subfields": isinstance(tc, dict) and all(
        k in tc for k in ("temporal_coverage", "observed_days", "days_in_period", "largest_gap_days")),
    "coverage_basis present": isinstance(cb, dict)
        and isinstance(cb.get("operator_declared"), list) and isinstance(cb.get("machine_derived"), list),
    "cross_period_log absent": "cross_period_log" not in r["integrity"],
}
bad = [k for k, v in checks.items() if not v]
if bad:
    print("failed: " + ", ".join(bad)); sys.exit(1)
print("schema=%s, coverage_basis=%d operator/%d machine" % (
    r["schema_version"], len(cb["operator_declared"]), len(cb["machine_derived"])))
PY
)"; then
  ok "${note}"; record "1. schema v1.2 + fields" PASS "${note}"
else
  fail "v1.2 field assertion failed (${note:-no out-dense.json})"
  record "1. schema v1.2 + fields" FAIL "${note:-no out-dense.json}"
fi

# === Sub-test 2: dense continuity ===
step "2. dense continuity (1.0, 30/30, gap 0, no warning, disclaimer present)"
note=""
if [ -f "${TMP_DIR}/out-dense.json" ] \
   && ! grep -q "temporal coverage is" "${TMP_DIR}/dense.stderr" \
   && note="$(python3 - "${TMP_DIR}/out-dense.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); tc = r["aggregate"]["temporal_coverage"]
disc = [d for d in r.get("notes", {}).get("disclaimers", []) if "Temporal coverage" in d]
checks = {
    "temporal_coverage == 1.0": abs(tc["temporal_coverage"] - 1.0) < 1e-9,
    "observed == days == 30": tc["observed_days"] == 30 and tc["days_in_period"] == 30,
    "largest_gap == 0": tc["largest_gap_days"] == 0,
    "in-band disclaimer present": bool(disc),
}
bad = [k for k, v in checks.items() if not v]
if bad:
    print("failed: " + ", ".join(bad)); sys.exit(1)
print("coverage=1.0 30/30 gap=0, no stderr warning, disclaimer present")
PY
)"; then
  ok "${note}"; record "2. dense continuity" PASS "${note}"
else
  fail "dense continuity failed (${note:-stderr warning present or no output})"
  record "2. dense continuity" FAIL "${note:-stderr warning present or no output}"
fi

# === Sub-test 3: sparse continuity ===
step "3. sparse continuity (0.1, 3/30, gap 14, warning + disclaimer)"
note=""
if [ -f "${TMP_DIR}/out-sparse.json" ] \
   && grep -q "temporal coverage is 10.0%" "${TMP_DIR}/sparse.stderr" \
   && note="$(python3 - "${TMP_DIR}/out-sparse.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); tc = r["aggregate"]["temporal_coverage"]
disc = [d for d in r.get("notes", {}).get("disclaimers", []) if "Temporal coverage" in d]
checks = {
    "temporal_coverage == 0.1": abs(tc["temporal_coverage"] - 0.1) < 1e-9,
    "observed 3 / days 30": tc["observed_days"] == 3 and tc["days_in_period"] == 30,
    "largest_gap == 14": tc["largest_gap_days"] == 14,
    "in-band disclaimer present": bool(disc),
}
bad = [k for k, v in checks.items() if not v]
if bad:
    print("failed: " + ", ".join(bad)); sys.exit(1)
print("coverage=0.1 3/30 gap=14, stderr warning + disclaimer present")
PY
)"; then
  ok "${note}"; record "3. sparse continuity" PASS "${note}"
else
  fail "sparse continuity failed (${note:-no stderr warning or no output})"
  record "3. sparse continuity" FAIL "${note:-no stderr warning or no output}"
fi

# === Sub-test 4: verify-hash round-trip (temporal_coverage float in the hash) ===
step "4. verify-hash content_hash round-trips (dense + sparse), tampered fails"
t4="FAIL"; t4note=""
# Capture the verify-hash JSON first (|| true swallows its non-zero exit:
# unsigned reports are PARTIAL=2, tampered are UNTRUSTED=1), THEN parse — so a
# non-zero exit under `pipefail` cannot spuriously append "unknown".
ch() {
  local vh
  vh="$(in_image verify-hash --report "/workdir/$1" --no-identity-check --format json 2>/dev/null || true)"
  printf '%s' "${vh}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['verifications']['content_hash']['status'])" 2>/dev/null \
    || echo unknown
}
if [ -f "${TMP_DIR}/out-dense.json" ] && [ -f "${TMP_DIR}/out-sparse.json" ]; then
  d_ok="$(ch out-dense.json)"; s_ok="$(ch out-sparse.json)"
  python3 - "${TMP_DIR}/out-dense.json" "${TMP_DIR}/out-dense-tampered.json" <<'PY' || true
import json, sys
r = json.load(open(sys.argv[1]))
r["aggregate"]["temporal_coverage"]["observed_days"] += 1
json.dump(r, open(sys.argv[2], "w"), indent=2)
PY
  t_fail="$(ch out-dense-tampered.json)"
  if [ "${d_ok}" = "ok" ] && [ "${s_ok}" = "ok" ] && [ "${t_fail}" = "fail" ]; then
    t4="PASS"; t4note="dense/sparse content_hash ok, tampered fail"
  else
    t4note="dense=${d_ok}, sparse=${s_ok} (want ok), tampered=${t_fail} (want fail)"
  fi
else
  t4note="dense/sparse output missing"
fi
if [ "${t4}" = "PASS" ]; then ok "${t4note}"; else fail "${t4note}"; fi
record "4. verify-hash round-trip" "${t4}" "${t4note}"

# === Sub-test 5: v1.2 validator reject (requests_measured > total_requests_in_period) ===
step "5. official rejects requests_measured > total_requests_in_period (v1.2 rule)"
# Insert the key right after the [scope_manifest] header. awk (not `sed s/\n/`)
# because `\n` in a sed replacement is GNU-only, not portable to BSD sed.
awk '1; /^\[scope_manifest\]$/ { print "total_requests_in_period = 1" }' \
  "${TMP_DIR}/org-config.toml" > "${TMP_DIR}/org-config-badrequests.toml"
rm -f "${TMP_DIR}/out-c5.json"
out5="$(in_image disclose --intent official --confidentiality public "${PERIOD_ARGS[@]}" \
  --input /workdir/reports-dense.ndjson --output /workdir/out-c5.json \
  --org-config /workdir/org-config-badrequests.toml 2>&1 || true)"
if [[ "${out5}" == *"total_requests_in_period"* ]] && [ ! -f "${TMP_DIR}/out-c5.json" ]; then
  ok "official rejected on the v1.2 requests rule, no file written"
  record "5. v1.2 requests reject" PASS "rejected: requests_measured > total_requests_in_period"
else
  fail "expected reject on requests rule; got: $(echo "${out5}" | tail -1)"
  record "5. v1.2 requests reject" FAIL "no reject / file written"
fi

# === Aggregate verdict + report ===
overall="PASS"
for v in "${VERDICTS[@]}"; do [ "${v}" = "FAIL" ] && overall="FAIL"; done
{
  echo "# Scenario: ${SCENARIO}"
  echo
  echo "Image: ${IMAGE}"
  echo "Fixtures: scenarios/${SCENARIO}/fixtures/ (real 0.8.3-daemon line, ts varied, findings trimmed)"
  echo
  echo "| # | Name | Verdict | Note |"
  echo "| --- | --- | --- | --- |"
  for i in "${!NAMES[@]}"; do
    echo "| $((i+1)) | ${NAMES[$i]} | ${VERDICTS[$i]} | ${NOTES[$i]} |"
  done
  echo
  echo "## Verdict: ${overall}"
} > "${REPORT}"

if [ "${overall}" = "PASS" ]; then
  ok "PASS 5/5, see ${REPORT}"; exit 0
else
  fail "see ${REPORT}"; exit 1
fi
