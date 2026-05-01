#!/usr/bin/env bash
# B2-3 daemon receives OTLP HTTP directly from a service, no Collector.
#
# Use case: a minimal setup with no Tempo and no OTel Collector. The
# instrumented service points its OTLP exporter straight at the
# perf-sentinel daemon's HTTP endpoint (port 14318). The daemon ingests,
# correlates, and exposes findings via /api/export/report.

set -euo pipefail

SCENARIO="b2-3-daemon-otlp-direct"
NS="b2-3-direct-otlp"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
MANIFESTS="$(cd "$(dirname "$0")" && pwd)/manifests.yaml"
mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; cleanup; exit 1; }

PF_DAEMON_PID=""
PF_ORDER_PID=""
cleanup() {
  for pid in "${PF_DAEMON_PID}" "${PF_ORDER_PID}"; do
    if [ -n "${pid}" ]; then kill "${pid}" 2>/dev/null || true; fi
  done
  if [ "${KEEP_NAMESPACE:-no}" != "yes" ]; then
    kubectl delete namespace "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

verdict="UNKNOWN"
EVENTS=0; TRACES=0; FINDINGS=0

step "Mirror order-service-db secret to ${NS}"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n shop get secret order-service-db -o yaml \
  | sed -e "s/namespace: shop/namespace: ${NS}/" \
        -e '/resourceVersion:/d' -e '/uid:/d' -e '/creationTimestamp:/d' \
  | kubectl apply -f - >/dev/null
ok "secret order-service-db mirrored from shop"

step "Apply manifests"
kubectl apply -f "${MANIFESTS}" > "${TMP_DIR}/apply.log" 2>&1
ok "manifests applied"

step "Wait for the dedicated daemon to become Ready"
kubectl -n "${NS}" rollout status deploy/perf-sentinel-daemon-direct --timeout=120s
ok "daemon Ready"

step "Wait for the cloned order-service to become Ready"
kubectl -n "${NS}" rollout status deploy/order-service-direct --timeout=240s
sleep 20
ok "order-service-direct Ready (plus 20s for full Spring Boot startup)"

step "Port-forward the dedicated daemon on a free local port"
LOCAL_PORT=14418
kubectl -n "${NS}" port-forward svc/perf-sentinel-daemon-direct ${LOCAL_PORT}:14318 \
  > "${TMP_DIR}/pf-daemon.log" 2>&1 &
PF_DAEMON_PID=$!
for i in $(seq 1 30); do
  if curl -fsS "http://localhost:${LOCAL_PORT}/api/status" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -fsS "http://localhost:${LOCAL_PORT}/api/status" >/dev/null 2>&1 \
  || die "dedicated daemon not reachable on localhost:${LOCAL_PORT}"
ok "daemon reachable on localhost:${LOCAL_PORT}"

step "Port-forward order-service-direct and send a traffic burst"
ORDER_PORT=18080
kubectl -n "${NS}" port-forward svc/order-service ${ORDER_PORT}:8080 \
  > "${TMP_DIR}/pf-order.log" 2>&1 &
PF_ORDER_PID=$!
for i in $(seq 1 30); do
  if curl -fsS "http://localhost:${ORDER_PORT}/actuator/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -fsS "http://localhost:${ORDER_PORT}/actuator/health" >/dev/null 2>&1 \
  || die "order-service-direct not reachable on localhost:${ORDER_PORT}"

for i in $(seq 1 50); do
  curl -fsS -X POST -H 'Content-Type: application/json' -d '{}' \
    "http://localhost:${ORDER_PORT}/api/fault/n-plus-one-sql" >/dev/null 2>&1 || true
done
ok "50 POST requests sent to /api/fault/n-plus-one-sql"

step "Wait for the daemon to process spans"
sleep 15

step "Snapshot dedicated daemon report"
curl -fsS "http://localhost:${LOCAL_PORT}/api/export/report" > "${TMP_DIR}/direct-report.json"
EVENTS=$(python3 -c "import json; print(json.load(open('${TMP_DIR}/direct-report.json')).get('analysis', {}).get('events_processed', 0))")
TRACES=$(python3 -c "import json; print(json.load(open('${TMP_DIR}/direct-report.json')).get('analysis', {}).get('traces_analyzed', 0))")
FINDINGS=$(python3 -c "import json; print(len(json.load(open('${TMP_DIR}/direct-report.json')).get('findings', [])))")
ok "events=${EVENTS} traces=${TRACES} findings=${FINDINGS}"

if [ "${EVENTS}" -gt 0 ] && [ "${TRACES}" -gt 0 ]; then
  verdict="PASS"
else
  verdict="FAIL"
  kubectl -n "${NS}" logs deploy/perf-sentinel-daemon-direct --tail=30 > "${TMP_DIR}/daemon.log" 2>&1 || true
  kubectl -n "${NS}" logs deploy/order-service-direct --tail=30 > "${TMP_DIR}/order.log" 2>&1 || true
fi

step "Write report"
{
  echo "# B2-3 daemon receives OTLP HTTP directly (no Collector)"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Namespace: ${NS} (cleaned up after run unless KEEP_NAMESPACE=yes)"
  echo
  echo "Architecture:"
  echo "- order-service-direct (env OTEL_EXPORTER_OTLP_ENDPOINT pointing at perf-sentinel-daemon-direct:14318)"
  echo "- perf-sentinel-daemon-direct (this scenario's dedicated daemon, OTLP HTTP receiver native on 14318)"
  echo "- No OTel Collector deployed in this namespace, no Tempo"
  echo
  echo "## Daemon snapshot"
  echo
  echo "- events_processed: ${EVENTS}"
  echo "- traces_analyzed: ${TRACES}"
  echo "- findings: ${FINDINGS}"
  echo
  if [ "${verdict}" = "FAIL" ]; then
    echo "## Daemon logs (tail)"
    echo
    echo '```'
    tail -30 "${TMP_DIR}/daemon.log" 2>/dev/null || true
    echo '```'
    echo
    echo "## Order-service logs (tail)"
    echo
    echo '```'
    tail -30 "${TMP_DIR}/order.log" 2>/dev/null || true
    echo '```'
  fi
  echo
  echo "**Verdict: ${verdict}**"
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  ok "B2-3 PASS, see ${REPORT}"
  exit 0
else
  die "B2-3 ${verdict}, see ${REPORT}"
fi
