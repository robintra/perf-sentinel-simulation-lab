#!/usr/bin/env bash
# failure-mode-backend-down: validate that the daemon survives a panne
# of each backend (OTel collector, Tempo, Postgres) without crashing or
# panicking. The daemon in watch mode is independent from Tempo/Postgres
# and is upstream of the OTel collector, so the expected behaviour is
# graceful: /api/status keeps answering, no panic in logs.

set -euo pipefail

SCENARIO="failure-mode-backend-down"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
mkdir -p "${TMP_DIR}"

DAEMON_LOCAL_PORT="${DAEMON_LOCAL_PORT:-14318}"
PANNE_DURATION="${PANNE_DURATION:-30}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

VERDICTS=()

step "Sanity: daemon reachable on localhost:${DAEMON_LOCAL_PORT}"
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null \
  || die "daemon unreachable on localhost:${DAEMON_LOCAL_PORT}, run ./scripts/port-forward.sh start"
ok "daemon reachable"

# Sub-test runner. Args: label, namespace, kind, label-selector, timeout-restore.
run_subtest() {
  local label="$1" ns="$2" kind="$3" selector="$4" rt="$5"
  step "Sub-test: ${label} (${kind} -l ${selector} -n ${ns}) down ${PANNE_DURATION}s"

  local resource
  resource=$(kubectl -n "${ns}" get "${kind}" -l "${selector}" -o name 2>/dev/null | head -1)
  if [ -z "${resource}" ]; then
    VERDICTS+=("SKIP: ${label} not present in cluster (selector ${selector})")
    return
  fi

  local panics_before
  panics_before=$(kubectl -n observability logs deploy/perf-sentinel-daemon --since=10s 2>/dev/null \
    | grep -ic -E "panic|FATAL" || true)
  panics_before="${panics_before:-0}"

  local original_replicas
  original_replicas=$(kubectl -n "${ns}" get "${resource}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)
  original_replicas="${original_replicas:-1}"

  trap "kubectl -n ${ns} scale ${resource} --replicas=${original_replicas} >/dev/null 2>&1 || true" RETURN

  kubectl -n "${ns}" scale "${resource}" --replicas=0 > "${TMP_DIR}/${label}-scale0.log" 2>&1 \
    || { VERDICTS+=("SKIP: ${label} scale 0 failed (likely RBAC or kind mismatch)"); return; }
  sleep "${PANNE_DURATION}"

  local daemon_alive_during
  daemon_alive_during=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null 2>&1 && echo yes || echo no)

  kubectl -n "${ns}" scale "${resource}" --replicas="${original_replicas}" > "${TMP_DIR}/${label}-restore.log" 2>&1 || true
  case "${kind}" in
    deployment) kubectl -n "${ns}" rollout status "${resource}" --timeout="${rt}" >/dev/null 2>&1 || true ;;
    statefulset) kubectl -n "${ns}" rollout status "${resource}" --timeout="${rt}" >/dev/null 2>&1 || true ;;
  esac
  sleep 5

  local daemon_alive_after
  daemon_alive_after=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null 2>&1 && echo yes || echo no)

  local panics_total
  panics_total=$(kubectl -n observability logs deploy/perf-sentinel-daemon --since=2m 2>/dev/null \
    | grep -ic -E "panic|FATAL" || true)
  panics_total="${panics_total:-0}"
  local panics_delta=$(( panics_total - panics_before ))

  if [ "${daemon_alive_during}" = "yes" ] \
     && [ "${daemon_alive_after}" = "yes" ] \
     && [ "${panics_delta}" -le 0 ]; then
    VERDICTS+=("PASS: ${label} (alive_during=${daemon_alive_during} alive_after=${daemon_alive_after} panic_delta=${panics_delta})")
  else
    VERDICTS+=("FAIL: ${label} (alive_during=${daemon_alive_during} alive_after=${daemon_alive_after} panic_delta=${panics_delta})")
  fi
}

run_subtest "otel-collector-down" "observability" "deployment" "app.kubernetes.io/name=opentelemetry-collector" "120s"
run_subtest "tempo-down"          "observability" "statefulset" "app.kubernetes.io/name=tempo"                  "180s"
run_subtest "postgres-down"       "db"            "statefulset" "app.kubernetes.io/name=postgres"               "180s"

step "Aggregate verdicts"
verdict="PASS"
for v in "${VERDICTS[@]}"; do
  echo "    ${v}"
  if echo "${v}" | grep -q "^FAIL"; then
    verdict="FAIL"
  fi
done

if [ "${verdict}" = "FAIL" ]; then
  kubectl -n observability logs deploy/perf-sentinel-daemon --tail=120 > "${TMP_DIR}/daemon.log" 2>&1 || true
fi

step "Write report"
{
  echo "# failure-mode-backend-down"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Sub-tests: 3 (each scales the backend to 0 for ${PANNE_DURATION}s, then restores)"
  echo
  echo "## Sub-test verdicts"
  echo
  for v in "${VERDICTS[@]}"; do
    echo "- ${v}"
  done
  echo
  if [ "${verdict}" = "FAIL" ]; then
    echo "## Daemon logs (tail)"
    echo
    echo '```'
    tail -120 "${TMP_DIR}/daemon.log" 2>/dev/null || true
    echo '```'
    echo
  fi
  echo "**Verdict: ${verdict}**"
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  ok "PASS, see ${REPORT}"
  exit 0
else
  die "${verdict}, see ${REPORT}"
fi
