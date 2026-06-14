#!/usr/bin/env bash
# measured-energy-chain: locks the Kepler and Redfish scraper
# integrations introduced in perf-sentinel v0.7.4.
#
# Four sub-tests. 7.A-7.C observe the mock-side (the daemon-to-exporter
# plumbing). 7.D closes the loop daemon-report-side, asserting the
# scraped energy actually reaches the carbon output:
#   7.A  kepler-mock is Ready and the daemon has scraped /metrics
#        within the last KEPLER_WAIT_SEC window
#   7.B  redfish-mock is Ready and the daemon has scraped both
#        schemas v0.7.6 dispatches on within REDFISH_WAIT_SEC:
#        chassis-1 on /Power (legacy_power) and chassis-2 on
#        /EnvironmentMetrics (environment_metrics).
#   7.C  the daemon log scoped to the scenario window contains zero
#        "Kepler endpoint replied HTTP 200 but no samples matched"
#        warns. Direct evidence that the mock's metric name matches
#        the daemon parser expectation (Kepler v0.10+
#        `kepler_container_cpu_joules_total`).
#   7.D  a traffic burst to a mapped service (order-service) makes the
#        daemon report's per_service_energy_model[order-service] name a
#        measured backend (scaphandre_rapl > kepler_ebpf > redfish_bmc >
#        cloud_specpower), not the io_proxy_* estimate. This is the
#        "measured, not estimated" claim: the scraped joules were
#        attributed to a service, not just received off the wire. The
#        per-service tag is read, not the window-level energy_model,
#        which Electricity Maps masks to electricity_maps_api.
#
# Why 7.A-7.C stay mock-side: they prove the daemon-to-mock plumbing
# (NetworkPolicy, DNS, scraper config) is wired, a tighter signal than
# the report and free of span-timing flakiness. 7.D pays the traffic
# burst on purpose because attribution provenance is the one thing the
# mock-side hit counts cannot show. The full precedence MATRIX across
# every rank stays locked by upstream unit tests in
# crates/sentinel-core/src/score/region_breakdown.rs, 7.D only asserts
# the top measured rank wins over the proxy fallback.

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

# 7.D config. Daemon API as port-forwarded by scripts/port-forward.sh,
# the mapped service whose spans drive attribution, and the budget to
# wait for a batch carrying a measured model. ENERGY_POLL_SEC must cover
# one Scaphandre scrape (5s) plus a batch close.
DAEMON_URL="${DAEMON_URL:-http://localhost:14318}"
ORDER_NS="${ORDER_NS:-shop}"
ORDER_LOCAL_PORT="${ORDER_LOCAL_PORT:-18099}"
TRAFFIC_REQUESTS="${TRAFFIC_REQUESTS:-40}"
ENERGY_POLL_SEC="${ENERGY_POLL_SEC:-45}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

# 7.D opens an ephemeral port-forward to order-service. Reap it on any
# exit so a failed run never leaks a kubectl forward.
PF_ORDER_PID=""
cleanup() {
  if [ -n "${PF_ORDER_PID}" ]; then kill "${PF_ORDER_PID}" 2>/dev/null || true; fi
}
trap cleanup EXIT

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

step "7.C: kepler happy path (no zero-sample warn over scenario window)"
# 25s covers ZERO_SAMPLE_WARN_THRESHOLD = 3 ticks at 5s, plus two
# extra ticks of margin so a fresh post-rollout daemon (whose first
# warn cannot fire before T+15s) cannot slip into the window. The
# `kubectl --since` window starts now (after 7.A and 7.B have given
# the scrapers time to settle), so the assertion measures steady-
# state kepler health rather than startup transients.
KEPLER_WARN_WINDOW_SEC="${KEPLER_WARN_WINDOW_SEC:-25}"
sleep "${KEPLER_WARN_WINDOW_SEC}"
KEPLER_WARN_HITS=$(kubectl -n "${NS}" logs deploy/perf-sentinel-daemon \
                     --since="${KEPLER_WARN_WINDOW_SEC}s" 2>/dev/null \
                   | awk '/Kepler endpoint replied HTTP 200 but no samples matched/ {c++} END {print c+0}')
if [ "${KEPLER_WARN_HITS}" -eq 0 ]; then
  VERDICTS+=("PASS: 7.C zero zero-sample warns over ${KEPLER_WARN_WINDOW_SEC}s window (kepler mock metric name matches daemon parser)")
else
  VERDICTS+=("FAIL: 7.C ${KEPLER_WARN_HITS} zero-sample warns over ${KEPLER_WARN_WINDOW_SEC}s window (kepler mock metric name drifted from daemon parser expectation)")
fi

step "7.D: measured energy reaches the carbon output (daemon report-side)"
# 7.A-C prove the daemon scrapes the exporters. 7.D proves the scraped
# energy is attributed: order-service is in the Scaphandre process_map
# (exe bin/java, cmdline order-service.jar) and the Kepler
# service_mappings (order-svc), so a traffic burst must surface a
# measured per_service_energy_model[order-service]. A non-measured tag
# here means the scrape landed but attribution fell through to the
# proxy or intensity-only window tag.
if ! curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1; then
  VERDICTS+=("FAIL: 7.D daemon not reachable at ${DAEMON_URL}, run 'scripts/port-forward.sh start' first")
elif ! kubectl -n "${ORDER_NS}" get svc order-service >/dev/null 2>&1; then
  VERDICTS+=("FAIL: 7.D order-service missing in ns ${ORDER_NS}, run 'make seed-services' first")
else
  kubectl -n "${ORDER_NS}" port-forward svc/order-service "${ORDER_LOCAL_PORT}:8080" \
    > "${TMP_DIR}/pf-order.log" 2>&1 &
  PF_ORDER_PID=$!
  # kubectl exits at once when the service has no ready endpoints yet, so
  # re-spawn the forward while waiting rather than probing a dead one.
  order_ready=no
  for _ in $(seq 1 60); do
    if curl -fsS "http://localhost:${ORDER_LOCAL_PORT}/actuator/health" >/dev/null 2>&1; then
      order_ready=yes; break
    fi
    if ! kill -0 "${PF_ORDER_PID}" 2>/dev/null; then
      kubectl -n "${ORDER_NS}" port-forward svc/order-service "${ORDER_LOCAL_PORT}:8080" \
        >> "${TMP_DIR}/pf-order.log" 2>&1 &
      PF_ORDER_PID=$!
    fi
    sleep 1
  done

  if [ "${order_ready}" != yes ]; then
    VERDICTS+=("FAIL: 7.D order-service not reachable on localhost:${ORDER_LOCAL_PORT} within 60s")
  else
    # Drive an N+1 SQL fault burst so order-service spans land in the
    # daemon's scoring window.
    for _ in $(seq 1 "${TRAFFIC_REQUESTS}"); do
      curl -fsS -X POST -H 'Content-Type: application/json' -d '{}' \
        "http://localhost:${ORDER_LOCAL_PORT}/api/fault/n-plus-one-sql" >/dev/null 2>&1 || true
    done

    # Assert the PER-SERVICE energy model for order-service, not the
    # window-level green_summary.energy_model. The window tag is
    # select_co2_model_tag(flags), which Electricity Maps masks to
    # electricity_maps_api whenever real-time intensity is active (the lab
    # configures it), so a correctly attributed Scaphandre run would read
    # electricity_maps_api at the window level. The per-service tag is
    # measured_model.unwrap_or(window_model): it stays scaphandre_rapl when
    # attribution resolves and only inherits the window tag when the
    # service had no measured span. That also pins the verdict to the burst
    # target rather than any ambient measured service.
    # Keep polling while empty or non-measured (a batch can close before
    # the first Scaphandre sample for the window exists); break on the
    # first measured reading, else retain the last for the message.
    SVC="order-service"
    ENERGY_MODEL=""; ENERGY_KWH="0.0"
    deadline=$(( $(date +%s) + ENERGY_POLL_SEC ))
    while [ "$(date +%s)" -lt "${deadline}" ]; do
      sleep 5
      curl -fsS "${DAEMON_URL}/api/export/report" > "${TMP_DIR}/energy-report.json" 2>/dev/null || continue
      PARSED=$(SVC="${SVC}" python3 - "${TMP_DIR}/energy-report.json" <<'PY'
import json, os, sys
svc = os.environ["SVC"]
try:
    g = json.load(open(sys.argv[1])).get("green_summary", {}) or {}
except Exception:
    g = {}
model = (g.get("per_service_energy_model") or {}).get(svc, "")
kwh = (g.get("per_service_energy_kwh") or {}).get(svc, 0.0)
print(f"{model}|{kwh}")
PY
) || PARSED="|0.0"
      ENERGY_MODEL="${PARSED%%|*}"
      ENERGY_KWH="${PARSED#*|}"
      case "${ENERGY_MODEL}" in
        scaphandre_rapl|kepler_ebpf|redfish_bmc|cloud_specpower) break ;;
      esac
    done

    case "${ENERGY_MODEL}" in
      scaphandre_rapl|kepler_ebpf|redfish_bmc|cloud_specpower)
        VERDICTS+=("PASS: 7.D per_service_energy_model[${SVC}]=${ENERGY_MODEL} (measured), per_service_energy_kwh=${ENERGY_KWH}, scraped energy attributed to ${SVC}") ;;
      "")
        VERDICTS+=("FAIL: 7.D ${SVC} absent from per_service_energy_model after ${ENERGY_POLL_SEC}s (burst produced no scored spans, or daemon predates per-service attribution)") ;;
      *)
        VERDICTS+=("FAIL: 7.D per_service_energy_model[${SVC}]=${ENERGY_MODEL} is not a measured energy backend (Scaphandre process_map / Kepler service_mappings did not resolve ${SVC}, it inherited the window proxy/intensity tag)") ;;
    esac
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
  echo "Sub-tests: 4 (kepler-mock integration, redfish-mock integration, kepler happy path, measured-energy attribution)"
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
