#!/usr/bin/env bash
# The Hub's derived per-finding status: active, likely_resolved, not_observed.
#
# Until 0.15.0 a fixed finding and a merely rare one left the Hub by the same
# door: retention, silently, after 180 days. The Hub now derives a status per
# finding, and for a GreenOps story the disappearance IS the story, so the
# distinction has to be right rather than merely present.
#
# `likely_resolved` is the hard one, and it is deliberately narrow: the finding
# must be quiet past ResolutionGrace AND its endpoint must still be heartbeating
# from a source that (a) is reachable and (b) actually observed THIS finding
# before. The last clause is what stops a sibling deployment from vouching for a
# finding it never saw.
#
# The isolated Hub polls the shared daemon so its sources read as reachable,
# then every assertion is driven by crafted imports rather than real traffic:
# no two lab fault endpoints share a (service, endpoint) pair, so the heartbeat
# condition cannot be produced by driving the sample services. The envelopes are
# derived from a real daemon envelope so their shape stays honest; only the
# identity fields are edited.
#
# Sub-tests:
#   1. a fresh finding is active
#   2. quiet past the grace with nothing heartbeating -> not_observed
#   3. quiet, with the same source still heartbeating the endpoint through
#      another finding -> likely_resolved
#   4. a heartbeat from a source that never saw the finding does NOT vouch
#
# The remaining clause of the CASE, a heartbeat from an UNREACHABLE source,
# needs a source whose poll has failed. PollInterval is global, so it cannot
# coexist here with the reachable-source cases above: it belongs to
# scenarios/hub-source-reachability, which owns an isolated pair and the
# partition machinery.

set -euo pipefail

SCENARIO="hub-derived-status"
NS="${HUB_STATUS_NS:-hub-derived-status}"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"

LOCAL_PORT="${HUB_STATUS_PORT:-8091}"
# Seconds, not minutes: the whole scenario has to fit inside a scenario run.
GRACE_SECS="${HUB_STATUS_GRACE_SECS:-20}"

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
ok "reusing the Hub image under validation: ${HUB_IMAGE}"

IMPORT_KEY="$(head -c 48 /dev/urandom | od -An -tx1 | tr -d ' \n')"

step "1. an isolated Hub with a seconds-scale ResolutionGrace"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "${NS}" create secret generic hub-import-key \
  --from-literal=import-key="${IMPORT_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Two sources, both pointing at an unroutable address: this scenario never
# polls, it imports. `witness` is the source that observes the findings;
# `stranger` exists only to prove a foreign heartbeat does not vouch.
python3 - "${TMP_DIR}/manifests.yaml" "${NS}" "${HUB_IMAGE}" "${GRACE_SECS}" <<'PY'
import json, sys
out, ns, image, grace = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
def source(sid, name):
    return {"Id": sid, "Name": name, "Environment": "lab",
            # Points at this Hub's OWN service, which is neither a joke nor a
            # loop. PollWorker polls once at startup BEFORE its first delay, and
            # the status CASE requires unreachable_since_ms to be NULL, so the
            # source has to be genuinely reachable. The shared daemon is not an
            # option: the zero-trust policy only admits a Hub in its own
            # namespace. The Hub serves the very contract DaemonClient expects,
            # /api/status with a version and /api/findings as an array, so the
            # boot poll succeeds against an empty store and imports nothing.
            "BaseUrl": f"http://hub.{ns}.svc.cluster.local:8080"}
settings = {"Hub": {
    "DatabasePath": "/data/hub.db",
    # Long, so only the startup poll runs: it succeeds against the shared
    # daemon, leaves unreachable_since_ms NULL, and nothing re-polls to disturb
    # the timing this scenario depends on. Reachability itself is proven in
    # scenarios/hub-source-reachability, which owns the partition machinery.
    "PollInterval": "23:00:00",
    "HttpTimeout": "00:00:02",
    "Retention": "180.00:00:00",
    "ResolutionGrace": f"00:00:{grace:02d}",
    "MaxReadLimit": 10000,
    "Sources": [source("witness", "witness source"), source("stranger", "stranger source")],
}}
# The JSON block is embedded in YAML, so every line needs the block indent.
indented = "\n".join("    " + line for line in json.dumps(settings, indent=2).splitlines())
manifest = f"""---
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
            - name: Hub__Sources__1__ImportApiKey
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
"""
open(out, "w").write(manifest)
PY

kubectl apply -f "${TMP_DIR}/manifests.yaml" >/dev/null
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
ok "isolated Hub ready, ResolutionGrace=${GRACE_SECS}s"

# Import helper: $1 = source_id, $2 = signature, $3 = endpoint, $4 = type
push() {
  python3 - "${TMP_DIR}/body.json" "$2" "$3" "$4" <<'PY'
import json, sys, time
out, signature, endpoint, ftype = sys.argv[1:5]
now = int(time.time() * 1000)
json.dump({"producer_version": "lab-status", "findings": [{
    "stored_at_ms": now, "first_seen_ms": now, "seen_count": 1,
    "finding": {
        "type": ftype, "severity": "warning", "trace_id": f"t-{signature[-8:]}",
        "service": "status-svc", "grouping": [], "source_endpoint": endpoint,
        "pattern": {"template": f"SELECT * FROM t WHERE k = ? /* {signature[-8:]} */",
                    "occurrences": 7, "window_ms": 500, "distinct_params": 7},
        "suggestion": "lab fixture",
        "first_timestamp": "2026-06-05T10:00:00.000Z",
        "last_timestamp": "2026-06-05T10:00:00.500Z",
        "confidence": "daemon_staging", "signature": signature,
    },
}]}, open(out, "w"))
PY
  curl -s -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:${LOCAL_PORT}/api/import/findings?source_id=$1" \
    -H "X-API-Key: ${IMPORT_KEY}" -H "Content-Type: application/json" \
    --data-binary "@${TMP_DIR}/body.json"
}

status_of() {  # $1 = signature
  curl -sf "http://127.0.0.1:${LOCAL_PORT}/api/findings?limit=1000" \
    | python3 -c '
import json, sys
sig = sys.argv[1]
for row in json.load(sys.stdin):
    if row.get("finding", {}).get("signature") == sig:
        print(row.get("status")); break
else:
    print("absent")
' "$1"
}

SIG_MAIN="n_plus_one_sql:status-svc:GET__orders:$(printf 'a%.0s' {1..32})"
SIG_HEARTBEAT="redundant_sql:status-svc:GET__orders:$(printf 'b%.0s' {1..32})"
SIG_LONELY="n_plus_one_sql:status-svc:GET__lonely:$(printf 'c%.0s' {1..32})"
SIG_FOREIGN="n_plus_one_sql:status-svc:GET__foreign:$(printf 'd%.0s' {1..32})"

# === 1: fresh is active ===
step "2. a fresh finding is active"
code="$(push witness "${SIG_MAIN}" "GET /orders" n_plus_one_sql)"
[ "${code}" = "200" ] || die "import failed with HTTP ${code}"
if [ "$(status_of "${SIG_MAIN}")" = "active" ]; then
  ok "active"
  record "fresh is active" PASS "active"
else
  fail "expected active, got $(status_of "${SIG_MAIN}")"
  record "fresh is active" FAIL "$(status_of "${SIG_MAIN}")"
fi

# === 3: quiet with nothing heartbeating -> not_observed ===
step "3. quiet past the grace with nothing heartbeating -> not_observed"
push witness "${SIG_LONELY}" "GET /lonely" n_plus_one_sql >/dev/null
sleep "$((GRACE_SECS + 4))"
if [ "$(status_of "${SIG_LONELY}")" = "not_observed" ]; then
  ok "not_observed: a quiet endpoint proves nothing"
  record "quiet is not_observed" PASS "not_observed"
else
  fail "expected not_observed, got $(status_of "${SIG_LONELY}")"
  record "quiet is not_observed" FAIL "$(status_of "${SIG_LONELY}")"
fi

# === 4: same source still heartbeating the endpoint -> likely_resolved ===
step "4. the witness keeps the endpoint alive through another finding -> likely_resolved"
# SIG_MAIN went quiet at least GRACE_SECS ago; a fresh finding from the SAME
# source on the SAME endpoint is the heartbeat that lets it read as resolved.
push witness "${SIG_HEARTBEAT}" "GET /orders" redundant_sql >/dev/null
sleep 3
got="$(status_of "${SIG_MAIN}")"
if [ "${got}" = "likely_resolved" ]; then
  ok "likely_resolved: the endpoint is alive and the witness is reachable"
  record "heartbeat resolves" PASS "likely_resolved"
else
  fail "expected likely_resolved, got ${got}"
  fail "source reachability: $(curl -sf "http://127.0.0.1:${LOCAL_PORT}/api/findings?limit=10" \
        | python3 -c 'import json,sys; print({s["status"] for r in json.load(sys.stdin) for s in r["sources"]})' 2>/dev/null)"
  record "heartbeat resolves" FAIL "${got}"
fi

# === 5: a foreign source's heartbeat does not vouch ===
step "5. a heartbeat from a source that never saw the finding does not vouch"
push witness "${SIG_FOREIGN}" "GET /foreign" n_plus_one_sql >/dev/null
sleep "$((GRACE_SECS + 4))"
# The stranger heartbeats the same endpoint, but never observed SIG_FOREIGN.
push stranger "n_plus_one_sql:status-svc:GET__foreign:$(printf 'e%.0s' {1..32})" \
     "GET /foreign" redundant_sql >/dev/null
sleep 3
got="$(status_of "${SIG_FOREIGN}")"
if [ "${got}" = "not_observed" ]; then
  ok "not_observed: a sibling source cannot vouch for a finding it never saw"
  record "foreign heartbeat" PASS "not_observed"
else
  fail "expected not_observed, got ${got}"
  fail "likely_resolved here is the pre-fix behaviour: any reachable source vouched"
  record "foreign heartbeat" FAIL "${got}"
fi

# === Report ===
{
  echo "# Scenario: ${SCENARIO}"
  echo
  echo "Hub image: \`${HUB_IMAGE}\`, ResolutionGrace ${GRACE_SECS}s"
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
