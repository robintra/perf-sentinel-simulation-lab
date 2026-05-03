#!/usr/bin/env bash
# failure-mode-network-partition: validate the daemon survives a
# network partition that isolates it from all cross-namespace OTLP
# producers. The daemon's own pod stays up but cannot receive new
# traffic. Expected behaviour: /api/status answers, no panic, no
# stuck state once the partition heals.

set -euo pipefail

SCENARIO="failure-mode-network-partition"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
MANIFESTS="$(cd "$(dirname "$0")" && pwd)/manifests.yaml"
mkdir -p "${TMP_DIR}"

DAEMON_LOCAL_PORT="${DAEMON_LOCAL_PORT:-14318}"
PARTITION_DURATION="${PARTITION_DURATION:-30}"
HEAL_DURATION="${HEAL_DURATION:-30}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; cleanup; exit 1; }

cleanup() {
  kubectl delete -f "${MANIFESTS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

verdict="UNKNOWN"
DAEMON_DURING="no"; DAEMON_AFTER="no"
PANICS_BEFORE=0; PANICS_AFTER=0; PANICS_DELTA=0

step "Sanity: daemon reachable on localhost:${DAEMON_LOCAL_PORT}"
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null \
  || die "daemon unreachable on localhost:${DAEMON_LOCAL_PORT}, run ./scripts/port-forward.sh start"
ok "daemon reachable"

PANICS_BEFORE=$(kubectl -n observability logs deploy/perf-sentinel-daemon --since=10s 2>/dev/null \
  | grep -ic -E "panic|FATAL" || true)
PANICS_BEFORE="${PANICS_BEFORE:-0}"
ok "panics_before=${PANICS_BEFORE}"

step "Apply isolation NetworkPolicy"
kubectl apply -f "${MANIFESTS}" > "${TMP_DIR}/apply.log" 2>&1
ok "NetworkPolicy applied"

step "Wait ${PARTITION_DURATION}s under partition, probe daemon"
sleep "${PARTITION_DURATION}"
DAEMON_DURING=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null 2>&1 && echo yes || echo no)
ok "daemon alive during partition (via port-forward): ${DAEMON_DURING}"

step "Heal partition (delete NetworkPolicy), wait ${HEAL_DURATION}s"
kubectl delete -f "${MANIFESTS}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
sleep "${HEAL_DURATION}"
DAEMON_AFTER=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null 2>&1 && echo yes || echo no)
ok "daemon alive after heal: ${DAEMON_AFTER}"

PANICS_AFTER=$(kubectl -n observability logs deploy/perf-sentinel-daemon --since=2m 2>/dev/null \
  | grep -ic -E "panic|FATAL" || true)
PANICS_AFTER="${PANICS_AFTER:-0}"
PANICS_DELTA=$(( PANICS_AFTER - PANICS_BEFORE ))
ok "panics_delta=${PANICS_DELTA}"

if [ "${DAEMON_DURING}" = "yes" ] \
   && [ "${DAEMON_AFTER}" = "yes" ] \
   && [ "${PANICS_DELTA}" -le 0 ]; then
  verdict="PASS"
else
  verdict="FAIL"
  kubectl -n observability logs deploy/perf-sentinel-daemon --tail=120 > "${TMP_DIR}/daemon.log" 2>&1 || true
fi

step "Write report"
{
  echo "# failure-mode-network-partition"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Partition duration: ${PARTITION_DURATION}s, heal duration: ${HEAL_DURATION}s"
  echo
  echo "## Verdicts"
  echo
  echo "- daemon /api/status answers during partition: ${DAEMON_DURING}"
  echo "- daemon /api/status answers after heal: ${DAEMON_AFTER}"
  echo "- panic/FATAL log delta (--since=2m): ${PANICS_DELTA}"
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
