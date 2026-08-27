#!/usr/bin/env bash
# Push and poll do not mean the same thing to a source's reachability.
#
# The Hub tracks whether it can reach each source. Only a SUCCESSFUL POLL clears
# that marker; a push never touches it. That asymmetry is deliberate and easy to
# get backwards: a daemon can be pushing perfectly while the Hub cannot reach it
# at all, and an operator reading "ok" in that state would be misled about
# whether the Hub could still fall back to polling.
#
# An isolated PAIR, daemon and Hub, in one namespace. The shared daemon is not
# an option: the zero-trust policy admits a polling Hub only from its own
# namespace, so a cross-namespace poll would fail for the wrong reason and the
# partition would prove nothing.
#
# The property under test is Hub-side, so the push half is issued with curl
# rather than by wiring a second daemon exporter: the Hub cannot tell the
# difference. The daemon here only has to answer /api/status and /api/findings,
# so it needs no traffic at all.
#
# One finding is seeded by push before the assertions begin. The source status
# is only observable through a finding's `sources[]` array, so without it every
# probe would read "no source" rather than ok or unreachable_since.
#
# The partition cuts only this Hub's egress, inside its own namespace. Nothing
# else in the cluster is disturbed, and port-forward keeps working because it
# goes through the kubelet proxy rather than the pod network.
#
# Sub-tests:
#   1. a reachable source reads ok
#   2. under partition the poll fails and the source reads unreachable_since
#   3. a push during the partition lands its finding WITHOUT clearing the marker
#   4. healing the partition clears it on the next poll

set -euo pipefail

SCENARIO="hub-source-reachability"
NS="${HUB_REACH_NS:-hub-source-reachability}"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"

LOCAL_PORT="${HUB_REACH_PORT:-8092}"
POLL_SECS="${HUB_REACH_POLL_SECS:-5}"

rm -rf "${TMP_DIR}"; mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
fail() { color_red   "    fail: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

PF_PID=""
cleanup() {
  [ -n "${PF_PID}" ] && kill "${PF_PID}" 2>/dev/null || true
  if [ "${KEEP_NAMESPACE:-no}" != "yes" ]; then
    kubectl delete namespace "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

declare -a NAMES=() VERDICTS=() NOTES=()
record() { NAMES+=("$1"); VERDICTS+=("$2"); NOTES+=("$3"); }

step "0. Pre-flight"
command -v kubectl >/dev/null || die "kubectl not on PATH"
command -v python3 >/dev/null || die "python3 not on PATH"
HUB_IMAGE="$(kubectl -n observability get deploy/perf-sentinel-hub \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
[ -n "${HUB_IMAGE}" ] || die "no Hub in the cluster. Run: make seed-hub-local"
DAEMON_IMAGE="$(kubectl -n observability get deploy/perf-sentinel-daemon \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
[ -n "${DAEMON_IMAGE}" ] || die "no daemon in the cluster to copy the image pin from"
ok "isolated pair: hub ${HUB_IMAGE}, daemon ${DAEMON_IMAGE}"

IMPORT_KEY="$(head -c 48 /dev/urandom | od -An -tx1 | tr -d ' \n')"

step "1. an isolated daemon and Hub, polling every ${POLL_SECS}s"
# Cleanup deletes with --wait=false, so a rerun can land while the previous
# namespace is still terminating. Creating into one is Forbidden, not a retry.
for _ in $(seq 1 60); do
  kubectl get namespace "${NS}" >/dev/null 2>&1 || break
  [ "$(kubectl get namespace "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Terminating" ] && break
  sleep 2
done
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "${NS}" create secret generic hub-import-key \
  --from-literal=import-key="${IMPORT_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# A minimal daemon: it only has to answer /api/status and /api/findings, so it
# needs no traffic, no archive and no green backends.
cat > "${TMP_DIR}/daemon.yaml" <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: daemon-config
  namespace: ${NS}
data:
  config.toml: |
    [daemon]
    listen_address = "0.0.0.0"
    listen_port_http = 14318
    listen_port_grpc = 14317
    api_enabled = true
    trace_ttl_ms = 5000
    environment = "staging"

    [daemon.ack]
    enabled = false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: daemon
  namespace: ${NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: daemon}}
  template:
    metadata:
      labels: {app: daemon}
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: perf-sentinel
          image: ${DAEMON_IMAGE}
          args: [watch, --config, /etc/perf-sentinel/config.toml]
          ports: [{name: http, containerPort: 14318}]
          volumeMounts:
            - {name: config, mountPath: /etc/perf-sentinel, readOnly: true}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
          readinessProbe:
            httpGet: {path: /health, port: http}
            periodSeconds: 2
      volumes:
        - name: config
          configMap: {name: daemon-config}
---
apiVersion: v1
kind: Service
metadata:
  name: daemon
  namespace: ${NS}
spec:
  selector: {app: daemon}
  ports: [{name: http, port: 14318, targetPort: http}]
EOF

python3 - "${TMP_DIR}/hub.yaml" "${NS}" "${HUB_IMAGE}" "${POLL_SECS}" <<'PY'
import json, sys
out, ns, image, poll = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
settings = {"Hub": {
    "DatabasePath": "/data/hub.db",
    "PollInterval": f"00:00:{poll:02d}",
    "HttpTimeout": "00:00:02",
    "Retention": "180.00:00:00",
    "ResolutionGrace": "01:00:00",
    "MaxReadLimit": 10000,
    "Sources": [{
        "Id": "lab-daemon", "Name": "isolated lab daemon", "Environment": "lab",
        "BaseUrl": f"http://daemon.{ns}.svc.cluster.local:14318",
    }],
}}
indented = "\n".join("    " + line for line in json.dumps(settings, indent=2).splitlines())
open(out, "w").write(f"""---
apiVersion: v1
kind: ConfigMap
metadata:
  name: hub-config
  namespace: {ns}
data:
  appsettings.Production.json: |
{indented}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hub
  namespace: {ns}
spec:
  replicas: 1
  strategy: {{type: Recreate}}
  selector: {{matchLabels: {{app: hub}}}}
  template:
    metadata:
      labels: {{app: hub}}
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1654
        runAsGroup: 1654
        fsGroup: 1654
        seccompProfile: {{type: RuntimeDefault}}
      containers:
        - name: hub
          image: {image}
          imagePullPolicy: Never
          ports: [{{name: http, containerPort: 8080}}]
          env:
            - name: ASPNETCORE_ENVIRONMENT
              value: Production
            - name: Hub__Sources__0__ImportApiKey
              valueFrom: {{secretKeyRef: {{name: hub-import-key, key: import-key}}}}
          volumeMounts:
            - {{name: config, mountPath: /app/appsettings.Production.json, subPath: appsettings.Production.json, readOnly: true}}
            - {{name: data, mountPath: /data}}
            - {{name: tmp, mountPath: /tmp}}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {{drop: [ALL]}}
          readinessProbe:
            httpGet: {{path: /health/ready, port: http}}
            periodSeconds: 2
      volumes:
        - name: config
          configMap: {{name: hub-config}}
        - name: data
          emptyDir: {{}}
        - name: tmp
          emptyDir: {{}}
---
apiVersion: v1
kind: Service
metadata:
  name: hub
  namespace: {ns}
spec:
  selector: {{app: hub}}
  ports: [{{name: http, port: 8080, targetPort: http}}]
""")
PY

# The partition: deny this Hub's egress to everything except DNS. Cutting DNS
# too would fail the lookup rather than the connection, which is a different
# failure and would classify differently in SourcePoller.
cat > "${TMP_DIR}/partition.yaml" <<EOF
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: hub-egress-blackhole
  namespace: ${NS}
spec:
  podSelector:
    matchLabels:
      app: hub
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
EOF

kubectl apply -f "${TMP_DIR}/daemon.yaml" >/dev/null
kubectl -n "${NS}" rollout status deploy/daemon --timeout=180s >/dev/null \
  || die "the isolated daemon did not become ready: $(kubectl -n "${NS}" logs deploy/daemon --tail=20 2>&1)"
kubectl apply -f "${TMP_DIR}/hub.yaml" >/dev/null
kubectl -n "${NS}" rollout status deploy/hub --timeout=180s >/dev/null \
  || die "the isolated Hub did not become ready: $(kubectl -n "${NS}" logs deploy/hub --tail=20 2>&1)"
# disown, so killing it in cleanup does not print a job-control notice
# over the scenario verdict.
kubectl -n "${NS}" port-forward svc/hub "${LOCAL_PORT}:8080" >"${TMP_DIR}/pf.log" 2>&1 &
PF_PID=$!
disown "${PF_PID}" 2>/dev/null || true
for _ in $(seq 1 40); do
  curl -sf "http://127.0.0.1:${LOCAL_PORT}/health/ready" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -sf "http://127.0.0.1:${LOCAL_PORT}/health/ready" >/dev/null \
  || die "the isolated Hub never answered /health/ready"
ok "isolated Hub ready"

# The per-source label the API exposes: "ok" or "unreachable_since".
source_status() {
  curl -sf "http://127.0.0.1:${LOCAL_PORT}/api/findings?limit=1000" 2>/dev/null \
    | python3 -c '
import json, sys
rows = json.load(sys.stdin)
labels = {s.get("status") for r in rows for s in r.get("sources", [])}
print(sorted(labels)[0] if labels else "no-source")
' 2>/dev/null || echo "unreadable"
}

findings_count() {
  curl -sf "http://127.0.0.1:${LOCAL_PORT}/api/findings?limit=1000" 2>/dev/null \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0
}

# One pushed finding, so a `sources[]` array exists to read a status from. The
# isolated daemon serves no findings of its own.
push_finding() {  # $1 = suffix, echoes the HTTP status
  python3 - "${TMP_DIR}/push-$1.json" "$1" <<'PUSHPY'
import json, sys, time
out, suffix = sys.argv[1], sys.argv[2]
now = int(time.time() * 1000)
json.dump({"producer_version": "lab-reach", "findings": [{
    "stored_at_ms": now, "first_seen_ms": now, "seen_count": 1,
    "finding": {
        "type": "n_plus_one_sql", "severity": "warning", "trace_id": "t-" + suffix,
        "service": "reach-svc", "grouping": [],
        "source_endpoint": "GET /" + suffix,
        "pattern": {"template": "SELECT * FROM " + suffix + " WHERE id = ?",
                    "occurrences": 9, "window_ms": 500, "distinct_params": 9},
        "suggestion": "lab fixture",
        "first_timestamp": "2026-06-05T10:00:00.000Z",
        "last_timestamp": "2026-06-05T10:00:00.500Z",
        "confidence": "daemon_staging",
        "signature": "n_plus_one_sql:reach-svc:GET__" + suffix + ":" + suffix[0] * 32,
    },
}]}, open(out, "w"))
PUSHPY
  curl -s -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:${LOCAL_PORT}/api/import/findings?source_id=lab-daemon" \
    -H "X-API-Key: ${IMPORT_KEY}" -H "Content-Type: application/json" \
    --data-binary "@${TMP_DIR}/push-$1.json"
}

# === 1: a reachable source reads ok ===
step "2. a reachable source reads ok"
# `|| true`: curl exits non-zero on a refused connection, and set -e would
# abort here before the HTTP-code check below could name the reason.
SEED_CODE="$(push_finding seed)" || true
[ "${SEED_CODE}" = "200" ] || die "the seed push failed with HTTP ${SEED_CODE}"
# PollWorker polls at boot and then every POLL_SECS; give it room to succeed.
BEFORE="no-source"
for _ in $(seq 1 12); do
  BEFORE="$(source_status)"
  [ "${BEFORE}" = "ok" ] && break
  sleep "${POLL_SECS}"
done
BEFORE_COUNT="$(findings_count)"
if [ "${BEFORE}" = "ok" ]; then
  ok "source reads ok after a successful poll (${BEFORE_COUNT} finding(s) stored)"
  record "reachable reads ok" PASS "ok, ${BEFORE_COUNT} findings"
else
  fail "source reads '${BEFORE}' with ${BEFORE_COUNT} finding(s)"
  fail "daemon log: $(kubectl -n "${NS}" logs deploy/daemon --tail=3 2>&1 | tr '\n' ' ')"
  record "reachable reads ok" FAIL "${BEFORE}"
fi

# === 2: partition -> unreachable_since ===
step "3. under partition the poll fails and the source reads unreachable_since"
kubectl apply -f "${TMP_DIR}/partition.yaml" >/dev/null
# Give the poll a few cycles to fail and mark the source.
sleep "$((POLL_SECS * 4))"
DURING="$(source_status)"
if [ "${DURING}" = "unreachable_since" ]; then
  ok "unreachable_since"
  record "partition marks unreachable" PASS "unreachable_since"
else
  fail "expected unreachable_since, got '${DURING}'"
  record "partition marks unreachable" FAIL "${DURING}"
fi

# === 3: a push during the partition does not clear the marker ===
step "4. a push during the partition lands its finding without clearing the marker"
PUSH_CODE="$(push_finding partitioned)" || true
sleep 2
AFTER_PUSH="$(source_status)"
PUSHED="$(curl -sf "http://127.0.0.1:${LOCAL_PORT}/api/findings?service=reach-svc&limit=100" \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)"
if [ "${PUSH_CODE}" = "200" ] && [ "${PUSHED}" -gt 0 ] && [ "${AFTER_PUSH}" = "unreachable_since" ]; then
  ok "the push committed (${PUSHED} finding) and the source still reads unreachable_since"
  record "push does not clear" PASS "pushed, still unreachable_since"
else
  fail "push HTTP ${PUSH_CODE}, ${PUSHED} finding(s), source reads '${AFTER_PUSH}'"
  fail "reading ok here would be the inversion: a push must never vouch for reachability"
  record "push does not clear" FAIL "${AFTER_PUSH}"
fi

# === 4: healing clears it ===
step "5. healing the partition clears the marker on the next poll"
kubectl delete -f "${TMP_DIR}/partition.yaml" --ignore-not-found --wait=true >/dev/null 2>&1 || true
HEALED="unreachable_since"
for _ in $(seq 1 12); do
  sleep "${POLL_SECS}"
  HEALED="$(source_status)"
  [ "${HEALED}" = "ok" ] && break
done
if [ "${HEALED}" = "ok" ]; then
  ok "back to ok after a successful poll"
  record "heal clears" PASS "ok"
else
  fail "still '${HEALED}' after the partition healed"
  record "heal clears" FAIL "${HEALED}"
fi

# === Report ===
{
  echo "# Scenario: ${SCENARIO}"
  echo
  echo "Hub image: \`${HUB_IMAGE}\`, PollInterval ${POLL_SECS}s"
  echo
  echo "| Sub-test | Verdict | Note |"
  echo "| --- | --- | --- |"
  for i in "${!NAMES[@]}"; do
    echo "| ${NAMES[$i]} | ${VERDICTS[$i]} | ${NOTES[$i]} |"
  done
} > "${REPORT}"

step "Report written to ${REPORT}"
for v in "${VERDICTS[@]}"; do
  [ "${v}" = "PASS" ] || { color_red "SCENARIO FAILED"; exit 1; }
done
color_green "SCENARIO PASSED"
