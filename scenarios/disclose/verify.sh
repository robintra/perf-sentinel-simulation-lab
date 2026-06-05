#!/usr/bin/env bash
# Periodic-disclosure two-tier avoidable-waste scenario (v0.8.2+, schema v1.1).
#
# Locks the v0.8.2 headline feature: `disclose` aggregates the per-window
# `canonical_waste` (binary-pinned N+1 threshold 2, operator cannot configure)
# and `operational_waste` (operator's configured threshold) tiers from archived
# NDJSON, with the flat avoidable fields aliasing the canonical tier.
#
# Hermetic CLI scenario (same family as intent-validator / verify-hash-roundtrip):
# `docker run ...:${PERF_SENTINEL_VERSION} disclose` over committed fixtures, no
# cluster/daemon contact. The fixtures are real v0.8.2-daemon per-window archives
# (findings arrays trimmed for size; the tiers live in `disclosure_waste` +
# `green_summary`, not `findings`):
#   - reports-thr5.ndjson   operator threshold 5,  canonical 2
#   - reports-thr50.ndjson  operator threshold 50, canonical 2 (same workload;
#                           n+1 reclassified to redundant at the high threshold)
#
# 4 sub-tests run inside `ghcr.io/robintra/perf-sentinel:${PERF_SENTINEL_VERSION}`
# (defaults to 0.8.2, the feature's introduction):
#
#   1. schema v1.1 + tiers: schema_version, canonical threshold == 2,
#      operational threshold == 5, both tiers energy/carbon > 0.
#   2. flat-field aliasing: estimated_optimization_potential_kgco2eq,
#      aggregate_waste_ratio, aggregate_efficiency_score alias the canonical tier.
#   3. official intent + verify-hash round-trip: `disclose --intent official`
#      passes the validator (exit 0) and `verify-hash` recomputes the
#      content_hash to OK (the disclose->verify round-trip fixed in v0.8.2 via
#      serde_json float_roundtrip; the gap verify-hash-roundtrip could not
#      close). A tampered copy must verify as FAIL.
#   4. anti-gaming invariant: over reports-thr50, canonical threshold stays 2
#      (UNCHANGED) while operational threshold is 50 and the canonical
#      waste_ratio strictly exceeds the operational one (the operator's high
#      threshold under-reports avoidable waste; the canonical headline is immune).
#
# Fixtures under fixtures/:
#   - reports-thr5.ndjson, reports-thr50.ndjson, org-config.toml
#     (org-config specpower_table_version tracks the pinned image's embedded CCF
#      vintage; bump it alongside PERF_SENTINEL_VERSION if the vintage changes.)

set -euo pipefail

SCENARIO="disclose"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES_DIR="${SCENARIO_DIR}/fixtures"

PERF_SENTINEL_VERSION="${PERF_SENTINEL_VERSION:-0.8.2}"
IMAGE="ghcr.io/robintra/perf-sentinel:${PERF_SENTINEL_VERSION}"

mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
fail() { color_red   "    fail: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

PERIOD_ARGS=(--period-type calendar-quarter --from 2026-04-01 --to 2026-06-30)

# === Pre-flight ===
step "0. Pre-flight"
command -v docker >/dev/null || die "docker not on PATH"
command -v python3 >/dev/null || die "python3 not on PATH"
for f in reports-thr5.ndjson reports-thr50.ndjson org-config.toml; do
  [ -f "${FIXTURES_DIR}/${f}" ] || die "fixture missing: ${f}"
done
docker image inspect "${IMAGE}" >/dev/null 2>&1 \
  || docker pull "${IMAGE}" >/dev/null 2>&1 \
  || die "cannot pull ${IMAGE}"
# Stage fixtures into TMP_DIR so docker mounts a single writable dir.
cp "${FIXTURES_DIR}/reports-thr5.ndjson"  "${TMP_DIR}/reports-thr5.ndjson"
cp "${FIXTURES_DIR}/reports-thr50.ndjson" "${TMP_DIR}/reports-thr50.ndjson"
cp "${FIXTURES_DIR}/org-config.toml"      "${TMP_DIR}/org-config.toml"
# Drop any output from a previous run so a stale file can never satisfy a
# later sub-test's `[ -f ... ]` guard if this run's disclose fails to write.
rm -f "${TMP_DIR}"/out-*.json
ok "fixtures + image OK (${IMAGE})"

# disclose is offline (no daemon contact); run as the host user so outputs are
# writable on the mounted dir.
in_image() {
  docker run --rm -u "$(id -u):$(id -g)" -v "${TMP_DIR}:/workdir" "${IMAGE}" "$@"
}

declare -a NAMES=() VERDICTS=() NOTES=()
record() { NAMES+=("$1"); VERDICTS+=("$2"); NOTES+=("$3"); }

# === Sub-test 1: schema v1.1 + tiers (internal/internal over thr5) ===
step "1. schema v1.1 + two tiers (canonical==2, operational==5, tiers non-zero)"
if in_image disclose --intent internal --confidentiality internal "${PERIOD_ARGS[@]}" \
     --input /workdir/reports-thr5.ndjson --output /workdir/out-thr5.json \
     --org-config /workdir/org-config.toml >/dev/null 2>&1 \
   && note="$(python3 - "${TMP_DIR}/out-thr5.json" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
ag = a["aggregate"]; cw = ag["canonical_waste"]; ow = ag["operational_waste"]
checks = {
    "schema v1.1": a["schema_version"] == "perf-sentinel-report/v1.1",
    "canonical thr==2": cw["n_plus_one_threshold"] == 2,
    "operational thr==5": ow["n_plus_one_threshold"] == 5,
    "canonical energy>0": cw["energy_kwh"] > 0,
    "canonical carbon>0": cw["carbon_kgco2eq"] > 0,
    "operational energy>0": ow["energy_kwh"] > 0,
    "operational carbon>0": ow["carbon_kgco2eq"] > 0,
}
bad = [k for k, v in checks.items() if not v]
if bad:
    print("failed: " + ", ".join(bad)); sys.exit(1)
print("schema=%s canonical_thr=%d operational_thr=%d" % (
    a["schema_version"], cw["n_plus_one_threshold"], ow["n_plus_one_threshold"]))
PY
)"; then
  ok "${note}"; record "1. schema v1.1 + tiers" PASS "${note}"
else
  fail "schema/tier assertion failed (${note:-disclose error})"
  record "1. schema v1.1 + tiers" FAIL "${note:-disclose error}"
fi

# === Sub-test 2: flat-field aliasing of the canonical tier ===
step "2. flat avoidable fields alias canonical_waste"
note=""
if [ -f "${TMP_DIR}/out-thr5.json" ] \
   && note="$(python3 - "${TMP_DIR}/out-thr5.json" <<'PY'
import json, sys
ag = json.load(open(sys.argv[1]))["aggregate"]; cw = ag["canonical_waste"]
checks = {
    "estimated_optimization_potential_kgco2eq": ag["estimated_optimization_potential_kgco2eq"] == cw["carbon_kgco2eq"],
    "aggregate_waste_ratio": ag["aggregate_waste_ratio"] == cw["waste_ratio"],
    "aggregate_efficiency_score": ag["aggregate_efficiency_score"] == cw["efficiency_score"],
}
bad = [k for k, v in checks.items() if not v]
if bad:
    print("not aliased: " + ", ".join(bad)); sys.exit(1)
print("3/3 flat fields alias canonical_waste")
PY
)"; then
  ok "${note}"; record "2. flat-field aliasing" PASS "${note}"
else
  fail "aliasing assertion failed (${note:-no out-thr5.json})"
  record "2. flat-field aliasing" FAIL "${note:-no out-thr5.json}"
fi

# === Sub-test 3: official intent + verify-hash round-trip ===
step "3. official intent validates + verify-hash content_hash round-trips"
t3="FAIL"; t3note=""
if in_image disclose --intent official --confidentiality public "${PERIOD_ARGS[@]}" \
     --input /workdir/reports-thr5.ndjson --output /workdir/out-official.json \
     --org-config /workdir/org-config.toml >/dev/null 2>&1; then
  vh="$(in_image verify-hash --report /workdir/out-official.json --no-identity-check --format json 2>/dev/null || true)"
  ch_ok="$(printf '%s' "${vh}" | python3 -c "import sys,json; print(json.load(sys.stdin)['verifications']['content_hash']['status'])" 2>/dev/null || echo unknown)"
  # tamper: mutate a field on the host, verify-hash must report content_hash fail.
  # Mutate canonical_waste.carbon_kgco2eq (sub-test 1 already proves it exists),
  # so a schema rename cannot KeyError here; `|| true` keeps a tamper-write
  # failure from aborting the whole script under `set -e` (it degrades to a
  # FAIL verdict instead, via the ch_tampered check below).
  python3 - "${TMP_DIR}/out-official.json" "${TMP_DIR}/out-official-tampered.json" <<'PY' || true
import json, sys
r = json.load(open(sys.argv[1]))
r["aggregate"]["canonical_waste"]["carbon_kgco2eq"] += 1.0
json.dump(r, open(sys.argv[2], "w"), indent=2)
PY
  vh_t="$(in_image verify-hash --report /workdir/out-official-tampered.json --no-identity-check --format json 2>/dev/null || true)"
  ch_tampered="$(printf '%s' "${vh_t}" | python3 -c "import sys,json; print(json.load(sys.stdin)['verifications']['content_hash']['status'])" 2>/dev/null || echo unknown)"
  if [ "${ch_ok}" = "ok" ] && [ "${ch_tampered}" = "fail" ]; then
    t3="PASS"; t3note="content_hash ok on untampered, fail on tampered"
  else
    t3note="content_hash untampered=${ch_ok} (want ok), tampered=${ch_tampered} (want fail)"
  fi
else
  t3note="official disclose did not exit 0 (validator rejected)"
fi
if [ "${t3}" = "PASS" ]; then ok "${t3note}"; else fail "${t3note}"; fi
record "3. official + verify-hash" "${t3}" "${t3note}"

# === Sub-test 4: anti-gaming invariant (over thr50) ===
step "4. anti-gaming: canonical pinned at 2 while operational(50) under-reports"
note=""
if in_image disclose --intent internal --confidentiality internal "${PERIOD_ARGS[@]}" \
     --input /workdir/reports-thr50.ndjson --output /workdir/out-thr50.json \
     --org-config /workdir/org-config.toml >/dev/null 2>&1 \
   && note="$(python3 - "${TMP_DIR}/out-thr50.json" <<'PY'
import json, sys
ag = json.load(open(sys.argv[1]))["aggregate"]; cw = ag["canonical_waste"]; ow = ag["operational_waste"]
checks = {
    "canonical thr==2 (unchanged)": cw["n_plus_one_threshold"] == 2,
    "operational thr==50": ow["n_plus_one_threshold"] == 50,
    "canonical.waste_ratio > operational.waste_ratio": cw["waste_ratio"] > ow["waste_ratio"],
}
bad = [k for k, v in checks.items() if not v]
if bad:
    print("failed: " + ", ".join(bad)); sys.exit(1)
print("canonical thr=2 wr=%.4f > operational thr=50 wr=%.4f" % (cw["waste_ratio"], ow["waste_ratio"]))
PY
)"; then
  ok "${note}"; record "4. anti-gaming invariant" PASS "${note}"
else
  fail "anti-gaming assertion failed (${note:-disclose error})"
  record "4. anti-gaming invariant" FAIL "${note:-disclose error}"
fi

# === Aggregate verdict + report ===
overall="PASS"
for v in "${VERDICTS[@]}"; do [ "${v}" = "FAIL" ] && overall="FAIL"; done
{
  echo "# Scenario: ${SCENARIO}"
  echo
  echo "Image: ${IMAGE}"
  echo "Fixtures: scenarios/${SCENARIO}/fixtures/ (real v0.8.2-daemon archives, findings trimmed)"
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
  ok "PASS 4/4, see ${REPORT}"; exit 0
else
  fail "see ${REPORT}"; exit 1
fi
