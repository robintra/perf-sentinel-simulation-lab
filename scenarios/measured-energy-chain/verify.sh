#!/usr/bin/env bash
# measured-energy-chain: locks the Kepler and Redfish scraper
# integrations introduced in perf-sentinel v0.7.4.
#
# Two sub-tests, both observed on the mock-side rather than via the
# daemon report:
#   7.A  kepler-mock is Ready and the daemon has scraped /metrics
#        within the last KEPLER_WAIT_SEC window
#   7.B  redfish-mock is Ready and the daemon has scraped both
#        schemas v0.7.6 dispatches on within REDFISH_WAIT_SEC:
#        chassis-1 on /Power (legacy_power) and chassis-2 on
#        /EnvironmentMetrics (environment_metrics).
#
# Why mock-side and not daemon-report-side: precedence selection in
# the daemon's report depends on which sources are reachable AND on
# per-service span observation timing, both of which would require
# either ConfigMap mutation (heavy) or a fresh traffic burst (slow).
# The mock-side hit counts are a tighter signal: they prove the
# daemon-to-mock plumbing (NetworkPolicy, DNS, scraper config) is
# fully wired, which is the actual lab-level integration concern.
# Precedence ordering itself is locked by upstream unit tests in
# crates/sentinel-core/src/score/region_breakdown.rs.

set -euo pipefail

SCENARIO="measured-energy-chain"
NS="observability"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
mkdir -p "${TMP_DIR}"

# Kepler ticks at 5s scrape_interval_secs, so 20s gives the daemon
# at least 3 chances to hit /metrics. Redfish at 60s needs a wider
# window: 75s allows for one full scrape cycle plus startup jitter.
KEPLER_WAIT_SEC="${KEPLER_WAIT_SEC:-20}"
REDFISH_WAIT_SEC="${REDFISH_WAIT_SEC:-75}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

VERDICTS=()

count_grep() {
  # grep -c can exit 1 when there are zero matches under set -e, so
  # we route through awk to always return a number with no error.
  awk -v pat="$1" 'index($0, pat) { c++ } END { print c+0 }' "$2"
}

logs_since_start() {
  # Pull deployment logs scoped to the scenario's observation window.
  # `kubectl --since` queries kubelet for lines newer than the given
  # duration, so the count returned reflects scrapes that actually
  # landed during the wait rather than the cumulative history since
  # mock pod start. +5s margin absorbs clock skew between the local
  # date(1) reading and kubelet's timestamping.
  # Args: <pod_label> <window_start_epoch> <out_file>
  local label="$1" window_start="$2" out="$3"
  local elapsed=$(( $(date +%s) - window_start + 5 ))
  kubectl -n "${NS}" logs deploy/"${label}" --since="${elapsed}s" > "${out}" 2>&1 || true
}

wait_for_hits() {
  # Poll a deployment's log within its scenario observation window
  # until <needle> appears or the budget expires. Returns the hit
  # count observed within the window (zero on timeout).
  # Args: <pod_label> <needle> <budget_seconds> <out_file>
  local label="$1" needle="$2" budget="$3" out="$4"
  local start
  start=$(date +%s)
  local deadline=$(( start + budget ))
  local hits=0
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    sleep 5
    logs_since_start "${label}" "${start}" "${out}"
    hits=$(count_grep "${needle}" "${out}")
    if [ "${hits}" -gt 0 ]; then
      echo "${hits}"
      return 0
    fi
  done
  echo "${hits}"
}

step "7.A: kepler-mock integration"
if ! kubectl -n "${NS}" wait --for=condition=Ready pod \
       -l app.kubernetes.io/name=kepler-mock --timeout=30s >/dev/null 2>&1; then
  VERDICTS+=("FAIL: 7.A kepler-mock not Ready in 30s, run 'make seed-kepler-mock' first")
else
  K_HITS=$(wait_for_hits "kepler-mock" "GET /metrics" "${KEPLER_WAIT_SEC}" "${TMP_DIR}/kepler-mock.log")
  if [ "${K_HITS}" -gt 0 ]; then
    VERDICTS+=("PASS: 7.A kepler-mock served ${K_HITS} /metrics scrapes within ${KEPLER_WAIT_SEC}s")
  else
    VERDICTS+=("FAIL: 7.A kepler-mock saw no /metrics scrapes within ${KEPLER_WAIT_SEC}s (daemon ConfigMap missing [green.kepler]?)")
  fi
fi

step "7.B: redfish-mock integration"
if ! kubectl -n "${NS}" wait --for=condition=Ready pod \
       -l app.kubernetes.io/name=redfish-mock --timeout=30s >/dev/null 2>&1; then
  VERDICTS+=("FAIL: 7.B redfish-mock not Ready in 30s, run 'make seed-redfish-mock' first")
else
  R_OUT="${TMP_DIR}/redfish-mock.log"
  R_START=$(date +%s)
  R_DEADLINE=$(( R_START + REDFISH_WAIT_SEC ))
  R1_HITS=0; R2_HITS=0
  while [ "$(date +%s)" -lt "${R_DEADLINE}" ]; do
    sleep 5
    logs_since_start "redfish-mock" "${R_START}" "${R_OUT}"
    R1_HITS=$(count_grep "GET /redfish/v1/Chassis/1/Power" "${R_OUT}")
    R2_HITS=$(count_grep "GET /redfish/v1/Chassis/2/EnvironmentMetrics" "${R_OUT}")
    if [ "${R1_HITS}" -gt 0 ] && [ "${R2_HITS}" -gt 0 ]; then
      break
    fi
  done
  if [ "${R1_HITS}" -gt 0 ] && [ "${R2_HITS}" -gt 0 ]; then
    VERDICTS+=("PASS: 7.B redfish-mock served chassis-1=${R1_HITS} (legacy_power) chassis-2=${R2_HITS} (environment_metrics) scrapes within ${REDFISH_WAIT_SEC}s")
  else
    VERDICTS+=("FAIL: 7.B redfish-mock missing chassis scrapes (chassis-1 Power=${R1_HITS} chassis-2 EnvironmentMetrics=${R2_HITS}) within ${REDFISH_WAIT_SEC}s")
  fi
fi

step "Aggregate verdicts"
verdict="PASS"
for v in "${VERDICTS[@]}"; do
  echo "    ${v}"
  if echo "${v}" | grep -q "^FAIL"; then
    verdict="FAIL"
  fi
done

step "Write report"
{
  echo "# measured-energy-chain"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Sub-tests: 2 (kepler-mock integration, redfish-mock integration)"
  echo
  echo "## Sub-test verdicts"
  echo
  for v in "${VERDICTS[@]}"; do
    echo "- ${v}"
  done
  echo
  echo "**Verdict: ${verdict}**"
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  ok "PASS, see ${REPORT}"
  exit 0
else
  die "${verdict}, see ${REPORT}"
fi
