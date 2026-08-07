#!/usr/bin/env bash
# failure-mode-daemon-restart: validate the daemon survives a rolling
# restart while OTLP traffic is in flight. Spans emitted during the
# rollout window may legitimately be lost (graceful drop), but the
# daemon must come back, accept new traffic, and not panic.

set -euo pipefail

SCENARIO="failure-mode-daemon-restart"
NS="failure-mode-daemon-restart"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
mkdir -p "${TMP_DIR}"

DAEMON_LOCAL_PORT="${DAEMON_LOCAL_PORT:-14318}"
PRE_RESTART_WAIT="${PRE_RESTART_WAIT:-60}"
POST_RESTART_WAIT="${POST_RESTART_WAIT:-60}"
TRAFFIC_DURATION="${TRAFFIC_DURATION:-180s}"
TRAFFIC_RATE="${TRAFFIC_RATE:-50}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; cleanup; exit 1; }

cleanup() {
  if [ "${KEEP_NAMESPACE:-no}" != "yes" ]; then
    kubectl delete networkpolicy perf-sentinel-allow-failure-mode-daemon-restart -n observability --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl delete namespace "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

verdict="UNKNOWN"
EVENTS_BASELINE=0; EVENTS_PRE=0; DELTA_PRE=0
EVENTS_POST=0; DELTA_POST=0
PANICS=0

step "Sanity: daemon reachable on localhost:${DAEMON_LOCAL_PORT}"
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null \
  || die "daemon unreachable on localhost:${DAEMON_LOCAL_PORT}, run ./scripts/port-forward.sh start"
ok "daemon reachable"

EVENTS_BASELINE=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/export/report" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('analysis', {}).get('events_processed', 0))")
ok "events_baseline=${EVENTS_BASELINE}"

step "Apply namespace, NetworkPolicies and traffic Job"
cat <<EOF | kubectl apply -f - > "${TMP_DIR}/apply.log" 2>&1
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels:
    app.kubernetes.io/part-of: perf-sentinel-lab
    pod-security.kubernetes.io/enforce: baseline
    name: ${NS}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: failure-mode-daemon-restart-egress
  namespace: ${NS}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: observability
          podSelector:
            matchLabels:
              app.kubernetes.io/name: perf-sentinel-daemon
      ports:
        - { protocol: TCP, port: 14318 }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: perf-sentinel-allow-failure-mode-daemon-restart
  namespace: observability
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: perf-sentinel-daemon
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ${NS}
      ports:
        - { protocol: TCP, port: 14318 }
---
apiVersion: batch/v1
kind: Job
metadata:
  name: restart-traffic
  namespace: ${NS}
spec:
  parallelism: 1
  completions: 1
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: telemetrygen
          image: ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen@sha256:4b60ea340031ce6c62f1043c35b3075f37eb91c01ad313bdb60f862ee4194062
          imagePullPolicy: IfNotPresent
          args:
            - traces
            - --otlp-endpoint=perf-sentinel-daemon.observability.svc.cluster.local:14318
            - --otlp-insecure
            - --otlp-http
            - --rate=${TRAFFIC_RATE}
            - --duration=${TRAFFIC_DURATION}
            - --service=restart-svc
            - '--telemetry-attributes=rpc.system="grpc"'
            - '--telemetry-attributes=rpc.service="restart-test"'
            - '--telemetry-attributes=rpc.method="Call"'
          resources:
            requests: { cpu: 20m, memory: 32Mi }
            limits:   { cpu: 100m, memory: 64Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ALL]
EOF
ok "manifests applied"

step "Wait ${PRE_RESTART_WAIT}s of nominal traffic"
sleep "${PRE_RESTART_WAIT}"
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/export/report" > "${TMP_DIR}/report-pre.json"
EVENTS_PRE=$(python3 -c "import json; print(json.load(open('${TMP_DIR}/report-pre.json')).get('analysis', {}).get('events_processed', 0))")
DELTA_PRE=$(( EVENTS_PRE - EVENTS_BASELINE ))
ok "events_pre=${EVENTS_PRE} delta_pre=${DELTA_PRE}"

step "kubectl rollout restart deployment/perf-sentinel-daemon -n observability"
RESTART_START=$(date +%s)
kubectl -n observability rollout restart deployment/perf-sentinel-daemon
kubectl -n observability rollout status deployment/perf-sentinel-daemon --timeout=120s
RESTART_END=$(date +%s)
RESTART_ELAPSED=$(( RESTART_END - RESTART_START ))
ok "rollout complete in ${RESTART_ELAPSED}s"

step "Re-establish port-forward (the previous one is now stale)"
pkill -f "kubectl.*port-forward.*perf-sentinel-daemon" 2>/dev/null || true
rm -f "$(cd "$(dirname "$0")/../.." && pwd)/tmp/pf-daemon.pid" 2>/dev/null || true
sleep 2
"$(cd "$(dirname "$0")/../.." && pwd)/scripts/port-forward.sh" start > "${TMP_DIR}/pf.log" 2>&1
for i in $(seq 1 60); do
  if curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null 2>&1; then
    ok "daemon reachable again after ${i}s post-restart"
    break
  fi
  sleep 1
done
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null \
  || die "daemon did not come back within 60s after rollout"

step "Wait ${POST_RESTART_WAIT}s for post-restart traffic to flow"
sleep "${POST_RESTART_WAIT}"
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/export/report" > "${TMP_DIR}/report-post.json"
EVENTS_POST=$(python3 -c "import json; print(json.load(open('${TMP_DIR}/report-post.json')).get('analysis', {}).get('events_processed', 0))")
DELTA_POST="${EVENTS_POST}"
ok "events_post=${EVENTS_POST} (counter resets across restart, so absolute is the post-restart total)"

step "Scan daemon logs for panics or fatal errors since restart"
PANICS=$(kubectl -n observability logs deploy/perf-sentinel-daemon --since=5m 2>/dev/null \
  | grep -ic -E "panic|FATAL" || true)
PANICS="${PANICS:-0}"
ok "panic/FATAL hits: ${PANICS}"

DAEMON_ALIVE=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null 2>&1 && echo yes || echo no)
PASS_PRE_TRAFFIC=$([ "${DELTA_PRE}" -gt 0 ] && echo yes || echo no)
PASS_POST_TRAFFIC=$([ "${DELTA_POST}" -gt 0 ] && echo yes || echo no)
PASS_NO_PANIC=$([ "${PANICS}" -eq 0 ] && echo yes || echo no)

if [ "${DAEMON_ALIVE}" = "yes" ] \
   && [ "${PASS_PRE_TRAFFIC}" = "yes" ] \
   && [ "${PASS_POST_TRAFFIC}" = "yes" ] \
   && [ "${PASS_NO_PANIC}" = "yes" ]; then
  verdict="PASS"
else
  verdict="FAIL"
  kubectl -n observability logs deploy/perf-sentinel-daemon --tail=80 > "${TMP_DIR}/daemon.log" 2>&1 || true
fi

step "Write report"
{
  echo "# failure-mode-daemon-restart"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Namespace: ${NS} (cleaned up after run unless KEEP_NAMESPACE=yes)"
  echo
  echo "## Timeline"
  echo
  echo "- traffic Job rate=${TRAFFIC_RATE}sps duration=${TRAFFIC_DURATION}"
  echo "- nominal window: ${PRE_RESTART_WAIT}s, events delta: ${DELTA_PRE} (${EVENTS_BASELINE} -> ${EVENTS_PRE})"
  echo "- rollout restart elapsed: ${RESTART_ELAPSED}s"
  echo "- post-restart window: ${POST_RESTART_WAIT}s, events at end: ${EVENTS_POST}"
  echo
  echo "## Verdicts"
  echo
  echo "- daemon /api/status answers post-restart: ${DAEMON_ALIVE}"
  echo "- traffic active before restart (events delta > 0): ${PASS_PRE_TRAFFIC}"
  echo "- ingestion resumed (events_post > 0): ${PASS_POST_TRAFFIC}"
  echo "- no panic/FATAL in --since=5m logs: ${PASS_NO_PANIC} (count: ${PANICS})"
  echo
  if [ "${verdict}" = "FAIL" ]; then
    echo "## Daemon logs (tail)"
    echo
    echo '```'
    tail -80 "${TMP_DIR}/daemon.log" 2>/dev/null || true
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
