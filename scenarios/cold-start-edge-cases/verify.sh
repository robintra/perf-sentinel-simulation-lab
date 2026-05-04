#!/usr/bin/env bash
# cold-start-edge-cases: 4 sub-tests of daemon cold-start corner cases.
#   6.A  zero-traffic cold-start
#   6.B  cold-start followed by an immediate high-volume burst
#   6.C  cold-start with a malformed TOML config (must fail-fast)
#   6.D  cold-start without the Electricity Maps secret (must degrade gracefully)
#
# Each rollout invalidates the existing kubectl port-forward, so the
# script tears down any stale forwards and relaunches them via
# scripts/port-forward.sh between sub-tests.

set -euo pipefail

SCENARIO="cold-start-edge-cases"
NS="cold-start-edge-cases"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "${TMP_DIR}"

DAEMON_LOCAL_PORT="${DAEMON_LOCAL_PORT:-14318}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; cleanup; exit 1; }

cleanup() {
  if [ -f "${TMP_DIR}/em-secret-backup.yaml" ]; then
    kubectl apply -f "${TMP_DIR}/em-secret-backup.yaml" >/dev/null 2>&1 || true
  fi
  if [ "${KEEP_NAMESPACE:-no}" != "yes" ]; then
    kubectl delete networkpolicy perf-sentinel-allow-cold-start-edge-cases -n observability --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl delete namespace "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

refresh_pf() {
  pkill -f "kubectl.*port-forward.*perf-sentinel-daemon" 2>/dev/null || true
  rm -f "${REPO_ROOT}/tmp/pf-daemon.pid" 2>/dev/null || true
  sleep 2
  "${REPO_ROOT}/scripts/port-forward.sh" start > "${TMP_DIR}/pf.log" 2>&1
  for i in $(seq 1 60); do
    if curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

VERDICTS=()

step "Sanity: daemon reachable on localhost:${DAEMON_LOCAL_PORT}"
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null \
  || die "daemon unreachable on localhost:${DAEMON_LOCAL_PORT}, run ./scripts/port-forward.sh start"
ok "daemon reachable"

# Sub-test 6.A: zero-traffic cold-start
step "6.A: zero-traffic cold-start"
kubectl -n observability rollout restart deployment/perf-sentinel-daemon >/dev/null
kubectl -n observability rollout status deployment/perf-sentinel-daemon --timeout=120s >/dev/null
refresh_pf || { VERDICTS+=("FAIL: 6.A daemon did not come back from rollout"); }
sleep 60
A_ALIVE=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null 2>&1 && echo yes || echo no)
A_REPORT=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/export/report" 2>/dev/null || echo '{}')
# 0.5.19+ exposes a structured warning_details[] array with a kind field.
# Fall back to the legacy warnings: [string] vec on older daemons.
A_COLD_START_KIND=$(echo "${A_REPORT}" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('parse_error'); sys.exit()
wd = d.get('warning_details') or []
if any(w.get('kind') == 'cold_start' for w in wd):
    print('yes_v0519')
elif any('cold-start' in w.lower() or 'not yet processed' in w.lower()
         for w in (d.get('warnings') or [])):
    print('yes_legacy')
else:
    print('no')
" 2>/dev/null || echo parse_error)

case "${A_COLD_START_KIND}" in
  yes_v0519) A_NOTE="cold_start kind in warning_details (0.5.19 surface)" ;;
  yes_legacy) A_NOTE="cold-start string in legacy warnings (0.5.18 fallback)" ;;
  *) A_NOTE="no cold-start signal (${A_COLD_START_KIND})" ;;
esac

if [ "${A_ALIVE}" = "yes" ] && [ "${A_COLD_START_KIND}" != "no" ] && [ "${A_COLD_START_KIND}" != "parse_error" ]; then
  VERDICTS+=("PASS: 6.A zero-traffic cold-start (alive=${A_ALIVE} ${A_NOTE})")
else
  VERDICTS+=("FAIL: 6.A zero-traffic cold-start (alive=${A_ALIVE} ${A_NOTE})")
fi

# Sub-test 6.B: cold-start + immediate high-volume burst
step "6.B: cold-start + immediate burst"
kubectl -n observability rollout restart deployment/perf-sentinel-daemon >/dev/null
kubectl -n observability rollout status deployment/perf-sentinel-daemon --timeout=120s >/dev/null
refresh_pf || { VERDICTS+=("FAIL: 6.B daemon did not come back from rollout"); }
B_EVENTS_BEFORE=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/export/report" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('analysis', {}).get('events_processed', 0))")

cat <<EOF | kubectl apply -f - > "${TMP_DIR}/6b-apply.log" 2>&1
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
  name: cold-start-edge-cases-egress
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
  name: perf-sentinel-allow-cold-start-edge-cases
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
  name: cold-burst
  namespace: ${NS}
spec:
  parallelism: 5
  completions: 5
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
            - --rate=200
            - --duration=30s
            - --service=cold-burst-svc
          resources:
            requests: { cpu: 20m, memory: 32Mi }
            limits:   { cpu: 100m, memory: 64Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ALL]
EOF
kubectl -n "${NS}" wait --for=condition=Complete --timeout=180s job/cold-burst > "${TMP_DIR}/6b-wait.log" 2>&1 || true
sleep 15
B_EVENTS_AFTER=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/export/report" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('analysis', {}).get('events_processed', 0))")
B_DELTA=$(( B_EVENTS_AFTER - B_EVENTS_BEFORE ))
B_ALIVE=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null 2>&1 && echo yes || echo no)
if [ "${B_ALIVE}" = "yes" ] && [ "${B_DELTA}" -gt 0 ]; then
  VERDICTS+=("PASS: 6.B cold-start + 5x200sps burst (delta=${B_DELTA}, alive=${B_ALIVE})")
else
  VERDICTS+=("FAIL: 6.B cold-start + burst (delta=${B_DELTA}, alive=${B_ALIVE})")
fi

# Sub-test 6.C: malformed TOML config (must fail-fast)
step "6.C: malformed TOML config"
cat > "${TMP_DIR}/bad-config.toml" <<'EOF'
[[invalid syntax here
this is not toml
EOF
DAEMON_IMAGE=$(kubectl -n observability get deployment perf-sentinel-daemon \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
if [ -z "${DAEMON_IMAGE}" ]; then
  VERDICTS+=("SKIP: 6.C could not read daemon image from observability/perf-sentinel-daemon")
else
  C_OUTPUT_FILE="${TMP_DIR}/6c-output.txt"
  C_EXIT=0
  # Portable timeout: docker run in background, monitor for self-exit
  # within 15s. If the daemon does not fail-fast, kill it. Avoids the
  # GNU `timeout` binary which is not installed on macOS by default.
  docker run --rm --name "bad-config-$$" \
    -v "${TMP_DIR}/bad-config.toml:/etc/perf-sentinel/config.toml:ro" \
    --user 65534:65534 \
    "${DAEMON_IMAGE}" \
    watch --config /etc/perf-sentinel/config.toml > "${C_OUTPUT_FILE}" 2>&1 &
  C_PID=$!
  C_DEADLINE=$(( $(date +%s) + 15 ))
  while kill -0 "${C_PID}" 2>/dev/null; do
    if [ "$(date +%s)" -ge "${C_DEADLINE}" ]; then
      docker kill "bad-config-$$" >/dev/null 2>&1 || true
      break
    fi
    sleep 1
  done
  wait "${C_PID}" 2>/dev/null || C_EXIT=$?
  C_NONZERO=$([ "${C_EXIT}" -ne 0 ] && echo yes || echo no)
  C_MENTIONS=$(grep -ic -E "invalid|parse|syntax|expected|TOML" "${C_OUTPUT_FILE}" || true)
  C_MENTIONS="${C_MENTIONS:-0}"
  if [ "${C_NONZERO}" = "yes" ] && [ "${C_MENTIONS}" -gt 0 ]; then
    VERDICTS+=("PASS: 6.C invalid config -> fail-fast (exit=${C_EXIT}, mentions=${C_MENTIONS})")
  else
    VERDICTS+=("FAIL: 6.C invalid config did not fail-fast (exit=${C_EXIT}, mentions=${C_MENTIONS})")
  fi
fi

# Sub-test 6.D: cold-start without Electricity Maps token
step "6.D: cold-start without EM token"
kubectl -n observability get secret perf-sentinel-electricity-maps -o yaml > "${TMP_DIR}/em-secret-backup.yaml" 2>/dev/null || true
if [ ! -s "${TMP_DIR}/em-secret-backup.yaml" ]; then
  VERDICTS+=("SKIP: 6.D EM secret not found, skipping (run make seed-electricity-maps first)")
else
  kubectl -n observability delete secret perf-sentinel-electricity-maps --ignore-not-found >/dev/null
  kubectl -n observability rollout restart deployment/perf-sentinel-daemon >/dev/null
  kubectl -n observability rollout status deployment/perf-sentinel-daemon --timeout=120s >/dev/null
  refresh_pf || true
  sleep 30
  D_ALIVE=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null 2>&1 && echo yes || echo no)
  D_REPORT_OK=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/export/report" >/dev/null 2>&1 && echo yes || echo no)
  kubectl apply -f "${TMP_DIR}/em-secret-backup.yaml" >/dev/null 2>&1 || true
  kubectl -n observability rollout restart deployment/perf-sentinel-daemon >/dev/null 2>&1 || true
  kubectl -n observability rollout status deployment/perf-sentinel-daemon --timeout=120s >/dev/null 2>&1 || true
  refresh_pf || true
  if [ "${D_ALIVE}" = "yes" ] && [ "${D_REPORT_OK}" = "yes" ]; then
    VERDICTS+=("PASS: 6.D no EM token, daemon survived (alive=${D_ALIVE} report_ok=${D_REPORT_OK})")
  else
    VERDICTS+=("FAIL: 6.D no EM token (alive=${D_ALIVE} report_ok=${D_REPORT_OK})")
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

if [ "${verdict}" = "FAIL" ]; then
  kubectl -n observability logs deploy/perf-sentinel-daemon --tail=120 > "${TMP_DIR}/daemon.log" 2>&1 || true
fi

step "Write report"
{
  echo "# cold-start-edge-cases"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Sub-tests: 4 (zero-traffic, burst, invalid-config, no-EM-token)"
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
