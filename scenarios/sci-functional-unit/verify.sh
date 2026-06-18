#!/usr/bin/env bash
# SCI per-functional-unit intensity (perf-sentinel 0.8.13, gate G1).
#
# 0.8.13 adds `green_summary.co2.sci_per_trace` (the SCI intensity per trace) and
# `green_summary.co2.functional_unit` alongside the existing footprint
# `co2.total`. The numerator footprint keeps methodology `sci_v1_numerator`; the
# new intensity carries `sci_v1_intensity` and divides the footprint by the
# number of traces analysed.
#
# Two surfaces:
#   batch  - `analyze --format json` with a carbon region configured
#            ([green] default_region) over a fixture that yields n_plus_one_sql
#            (artifacts/fixtures/em-real-time-traces.json).
#   daemon - `GET /api/export/report` must carry the same two fields. SKIPped
#            (not failed) when the daemon port-forward is unreachable, so the
#            scenario also runs hermetically.
#
# Image: ghcr.io/robintra/perf-sentinel:${PERF_SENTINEL_VERSION:-0.8.13}. For the
# unpublished pre-release, build + run with PERF_SENTINEL_VERSION=0.8.13-rc.

set -euo pipefail

SCENARIO="sci-functional-unit"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"
FIXTURES_DIR="${SCENARIO_DIR}/fixtures"

PERF_SENTINEL_VERSION="${PERF_SENTINEL_VERSION:-0.8.13}"
IMAGE="ghcr.io/robintra/perf-sentinel:${PERF_SENTINEL_VERSION}"
DAEMON_URL="${DAEMON_URL:-http://localhost:14318}"
TRACES="${REPO_ROOT}/artifacts/fixtures/em-real-time-traces.json"

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

# Assert the four SCI fields + the intensity invariant on a co2-bearing JSON
# report at $1 (any file with .green_summary.co2 and .analysis.traces_analyzed).
assert_sci() {
  local f="$1" label="$2"
  jq -e '.green_summary.co2.sci_per_trace | (.low and .mid and .high)' "$f" >/dev/null \
    || { fail "${label}: sci_per_trace missing low/mid/high"; return 1; }
  [ "$(jq -r '.green_summary.co2.sci_per_trace.methodology' "$f")" = "sci_v1_intensity" ] \
    || { fail "${label}: sci_per_trace.methodology != sci_v1_intensity"; return 1; }
  [ "$(jq -r '.green_summary.co2.functional_unit' "$f")" = "trace" ] \
    || { fail "${label}: functional_unit != trace"; return 1; }
  [ "$(jq -r '.green_summary.co2.total.methodology' "$f")" = "sci_v1_numerator" ] \
    || { fail "${label}: co2.total.methodology != sci_v1_numerator"; return 1; }
  # invariant: sci_per_trace.mid == total.mid / traces_analyzed (epsilon)
  jq -e '((.green_summary.co2.sci_per_trace.mid - (.green_summary.co2.total.mid / .analysis.traces_analyzed)) | (if . < 0 then -. else . end)) < 1e-9' "$f" >/dev/null \
    || { fail "${label}: invariant sci.mid == total.mid/traces failed"; return 1; }
  ok "${label}: sci_per_trace (sci_v1_intensity) + functional_unit=trace + invariant holds"
  return 0
}

# === Pre-flight ===
step "0. Pre-flight"
command -v docker >/dev/null || die "docker not on PATH"
command -v jq >/dev/null || die "jq not on PATH"
[ -f "${TRACES}" ] || die "trace fixture missing: ${TRACES}"
[ -f "${FIXTURES_DIR}/green.toml" ] || die "fixture missing: green.toml"
docker image inspect "${IMAGE}" >/dev/null 2>&1 || docker pull "${IMAGE}" >/dev/null 2>&1 || die "cannot get ${IMAGE}"
cp "${TRACES}" "${TMP_DIR}/traces.json"
cp "${FIXTURES_DIR}/green.toml" "${TMP_DIR}/green.toml"
ok "image + fixtures OK (${IMAGE})"

# === 1. batch ===
step "1. batch: analyze --format json with [green] default_region"
in_image analyze --input /workdir/traces.json --config /workdir/green.toml --format json \
  > "${TMP_DIR}/out.json" 2>"${TMP_DIR}/analyze-err.txt" || die "analyze failed: $(tail -2 "${TMP_DIR}/analyze-err.txt")"
jq -e '.green_summary.co2' "${TMP_DIR}/out.json" >/dev/null || die "no green_summary.co2 (region not applied?)"
if assert_sci "${TMP_DIR}/out.json" "batch"; then record "batch-sci" "PASS" "fields + invariant"
else record "batch-sci" "FAIL" "see log"; fi

# === 2. daemon ===
step "2. daemon: GET /api/export/report carries sci_per_trace + functional_unit"
if curl -fsS --max-time 5 "${DAEMON_URL}/api/status" >/dev/null 2>&1; then
  # Combine fetch + non-empty body so a 200 with an empty body still records a
  # verdict (the single else) instead of silently dropping the sub-test.
  if curl -fsS --max-time 10 "${DAEMON_URL}/api/export/report" > "${TMP_DIR}/export.json" 2>/dev/null \
     && [ -s "${TMP_DIR}/export.json" ]; then
    if jq -e '.green_summary.co2.total' "${TMP_DIR}/export.json" >/dev/null 2>&1; then
      if jq -e '.green_summary.co2.sci_per_trace and (.green_summary.co2.functional_unit=="trace")' "${TMP_DIR}/export.json" >/dev/null; then
        ok "daemon export carries co2.sci_per_trace + functional_unit=trace"
        record "daemon-sci" "PASS" "export carries sci_per_trace + functional_unit"
      else
        fail "daemon export missing sci_per_trace / functional_unit"
        record "daemon-sci" "FAIL" "fields absent on /api/export/report"
      fi
    else
      fail "daemon export has no co2 (cold start / no traffic ingested yet)"
      record "daemon-sci" "SKIP" "daemon co2 null (no batch scored yet)"
    fi
  else
    fail "GET /api/export/report failed or returned an empty body"
    record "daemon-sci" "FAIL" "endpoint error / empty body"
  fi
else
  ok "daemon unreachable at ${DAEMON_URL} -> SKIP (hermetic run)"
  record "daemon-sci" "SKIP" "daemon port-forward unreachable"
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
