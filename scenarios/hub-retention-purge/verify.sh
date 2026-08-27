#!/usr/bin/env bash
# Retention deletes findings. It must not delete the history they carried.
#
# The Hub purges rows whose last sighting fell outside the retention window.
# A superseded finding is exactly the kind of row that goes first, and its
# successor's whole claim to an accurate age rests on the predecessor's birth
# date. That date is denormalized onto the successor's lineage row on purpose,
# and `finding_lineage` is deliberately absent from the purge statement. Nothing
# asserted either half.
#
# `RetentionWorker` purges once at startup and then every 24 hours, so a
# rollout restart triggers a real pass without waiting a day. Retention is set
# to seconds here; the shared lab Hub keeps the 180-day default.
#
# A PVC, not an emptyDir: the restart is the trigger for the purge, so the
# database has to survive it. It also lets a Job run the image's `backup`
# argv mode against the same volume.
#
# The backup is checked by having a SECOND Hub open the backup file as its own
# database and serve from it, which proves more than a header sniff: a file
# that opens, migrates and answers /api/findings is a usable backup.
#
# Not covered here: upgrading a database written before the lineage columns
# existed. `EnsureLineageColumnsAsync` has no test in the Hub either, but
# staging a pre-migration file into a cluster volume needs an init container
# and a hand-built SQLite blob, which buys less than the unit test that belongs
# next to it.
#
# Sub-tests:
#   1. a predecessor and its successor are both stored, lineage linked
#   2. the boot purge drops the stale predecessor and keeps the fresh successor
#   3. the survivor's lineage still names the original birth, at depth 1
#   4. `backup` produces a database a second Hub can serve from

set -euo pipefail

SCENARIO="hub-retention-purge"
NS="${HUB_RETENTION_NS:-hub-retention-purge}"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"

HUB_PORT="${HUB_RETENTION_PORT:-8094}"
RESTORED_PORT="${HUB_RETENTION_RESTORED_PORT:-8095}"
# Seconds. The wait below is this plus a margin, so keep it small.
RETENTION_SECS="${HUB_RETENTION_SECS:-30}"

rm -rf "${TMP_DIR}"; mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
fail() { color_red   "    fail: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

PF_PID=""; PF_RESTORED_PID=""
cleanup() {
  [ -n "${PF_PID}" ] && kill "${PF_PID}" 2>/dev/null || true
  [ -n "${PF_RESTORED_PID}" ] && kill "${PF_RESTORED_PID}" 2>/dev/null || true
  if [ "${KEEP_NAMESPACE:-no}" != "yes" ]; then
    kubectl delete namespace "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

declare -a NAMES=() VERDICTS=() NOTES=()
record() { NAMES+=("$1"); VERDICTS+=("$2"); NOTES+=("$3"); }

step "0. Pre-flight"
command -v kubectl >/dev/null || die "kubectl not on PATH"
command -v curl >/dev/null || die "curl not on PATH"
command -v python3 >/dev/null || die "python3 not on PATH"
HUB_IMAGE="$(kubectl -n observability get deploy/perf-sentinel-hub \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
[ -n "${HUB_IMAGE}" ] || die "no Hub in the cluster. Run: make seed-hub-local"
ok "hub image ${HUB_IMAGE}, retention ${RETENTION_SECS}s"

IMPORT_KEY="$(head -c 48 /dev/urandom | od -An -tx1 | tr -d ' \n')"

step "1. an isolated Hub on a PVC, retention in seconds"
for _ in $(seq 1 60); do
  kubectl get namespace "${NS}" >/dev/null 2>&1 || break
  [ "$(kubectl get namespace "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Terminating" ] && break
  sleep 2
done
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "${NS}" create secret generic hub-import-key \
  --from-literal=import-key="${IMPORT_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

python3 - "${TMP_DIR}/hub.yaml" "${NS}" "${HUB_IMAGE}" "${RETENTION_SECS}" <<'PY'
import json, sys
out, ns, image, retention = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])


def settings(db_path):
    return {"Hub": {
        "DatabasePath": db_path,
        # Nothing is polled here; Sources[0] exists to carry the import key.
        "PollInterval": "23:00:00",
        "HttpTimeout": "00:00:02",
        "Retention": f"00:00:{retention:02d}",
        # HubOptionsValidator refuses a grace at or above the retention: a
        # finding cannot outlive its own resolution window. Nothing here reads
        # the derived status, so the smallest positive value will do.
        "ResolutionGrace": "00:00:01",
        "MaxReadLimit": 10000,
        "Sources": [{
            "Id": "lab-daemon", "Name": "import only", "Environment": "lab",
            "BaseUrl": "http://no-poll-target.invalid:14318",
        }],
    }}


def indent(obj):
    return "\n".join("    " + line for line in json.dumps(obj, indent=2).splitlines())


def deployment(name, config_map, port_name="http"):
    return f"""---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {name}
  namespace: {ns}
spec:
  replicas: 1
  # Recreate, not RollingUpdate: one writer per SQLite file, and the ReadWriteOnce
  # claim would leave a second pod Pending anyway.
  strategy: {{type: Recreate}}
  selector: {{matchLabels: {{app: {name}}}}}
  template:
    metadata:
      labels: {{app: {name}}}
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
          ports: [{{name: {port_name}, containerPort: 8080}}]
          env:
            - name: ASPNETCORE_ENVIRONMENT
              value: Production
            - name: Hub__Sources__0__ImportApiKey
              valueFrom:
                secretKeyRef: {{name: hub-import-key, key: import-key}}
          volumeMounts:
            - name: config
              mountPath: /app/appsettings.Production.json
              subPath: appsettings.Production.json
              readOnly: true
            - {{name: data, mountPath: /data}}
            - {{name: tmp, mountPath: /tmp}}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {{drop: [ALL]}}
          startupProbe:
            httpGet: {{path: /health/ready, port: {port_name}}}
            failureThreshold: 40
            periodSeconds: 2
      volumes:
        - name: config
          configMap:
            name: {config_map}
            items: [{{key: appsettings.Production.json, path: appsettings.Production.json}}]
        - name: data
          persistentVolumeClaim: {{claimName: hub-data}}
        - {{name: tmp, emptyDir: {{}}}}
---
apiVersion: v1
kind: Service
metadata:
  name: {name}
  namespace: {ns}
spec:
  selector: {{app: {name}}}
  ports: [{{name: http, port: 8080, targetPort: {port_name}}}]
"""


doc = f"""---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: hub-data
  namespace: {ns}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources: {{requests: {{storage: 256Mi}}}}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: hub-config
  namespace: {ns}
data:
  appsettings.Production.json: |
{indent(settings("/data/hub.db"))}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: hub-restored-config
  namespace: {ns}
data:
  appsettings.Production.json: |
{indent(settings("/data/backup.db"))}
"""
open(out, "w").write(doc + deployment("hub", "hub-config"))
open(sys.argv[1] + ".restored", "w").write(deployment("hub-restored", "hub-restored-config"))
PY

kubectl apply -f "${TMP_DIR}/hub.yaml" >/dev/null
kubectl -n "${NS}" rollout status deploy/hub --timeout=180s >/dev/null \
  || die "the isolated Hub did not become ready: $(kubectl -n "${NS}" logs deploy/hub --tail=20 2>&1)"

# $1 = service name, $2 = local port. Echoes the pid, so the caller reads it
# from a command substitution. That is why it must NOT die on failure: die
# writes to stdout, which inside $( ) lands in the caller's variable instead
# of on screen, and the assignment never happens, so the trap has no pid to
# kill and the disowned port-forward outlives the run holding the port. It
# echoes the pid either way and reports the failure through the exit status.
forward_hub() {
  kubectl -n "${NS}" port-forward "svc/$1" "$2:8080" >"${TMP_DIR}/pf-$1.log" 2>&1 &
  local pid=$!
  disown "${pid}" 2>/dev/null || true
  for _ in $(seq 1 40); do
    curl -sf "http://127.0.0.1:$2/health/ready" >/dev/null 2>&1 && break
    sleep 0.5
  done
  printf '%s' "${pid}"
  curl -sf "http://127.0.0.1:$2/health/ready" >/dev/null 2>&1
}
PF_PID="$(forward_hub hub "${HUB_PORT}")" || true
curl -sf "http://127.0.0.1:${HUB_PORT}/health/ready" >/dev/null \
  || die "hub not reachable on ${HUB_PORT}: $(tail -3 "${TMP_DIR}/pf-hub.log" 2>&1)"
ok "isolated Hub ready on ${HUB_PORT}"

# Two forged findings sharing service, type and endpoint, differing only by
# template. Forged rather than driven through a service: what is under test is
# the purge, and real traffic would only add a detection wait.
push() {  # $1 = suffix, $2 = extra SQL predicate, echoes the HTTP status
  python3 - "${TMP_DIR}/push-$1.json" "$1" "$2" <<'PY'
import json, sys, time
out, suffix, predicate = sys.argv[1], sys.argv[2], sys.argv[3]
now = int(time.time() * 1000)
json.dump({"producer_version": "lab-retention", "findings": [{
    "stored_at_ms": now, "first_seen_ms": now, "seen_count": 1,
    "finding": {
        "type": "n_plus_one_sql", "severity": "warning", "trace_id": "t-" + suffix,
        "service": "purge-svc", "grouping": [],
        "source_endpoint": "GET /purge",
        "pattern": {"template": "SELECT * FROM item WHERE id = ?" + predicate,
                    "occurrences": 9, "window_ms": 500, "distinct_params": 9},
        "suggestion": "lab fixture",
        "first_timestamp": "2026-06-05T10:00:00.000Z",
        "last_timestamp": "2026-06-05T10:00:00.500Z",
        "confidence": "daemon_staging",
        "signature": "n_plus_one_sql:purge-svc:GET__purge:" + suffix[0] * 32,
    },
}]}, open(out, "w"))
PY
  curl -s -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:${HUB_PORT}/api/import/findings?source_id=lab-daemon" \
    -H "X-API-Key: ${IMPORT_KEY}" -H "Content-Type: application/json" \
    --data-binary "@${TMP_DIR}/push-$1.json"
}

SIG_OLD="n_plus_one_sql:purge-svc:GET__purge:$(printf 'o%.0s' $(seq 1 32))"
SIG_NEW="n_plus_one_sql:purge-svc:GET__purge:$(printf 'n%.0s' $(seq 1 32))"

fetch_findings() {  # $1 = port, $2 = output file
  curl -sf "http://127.0.0.1:$1/api/findings?service=purge-svc&limit=1000" > "$2"
}
envelope_field() {  # $1 = file, $2 = signature, $3 = dotted path
  python3 -c '
import json, sys
sig, path = sys.argv[2], sys.argv[3].split(".")
for e in json.load(open(sys.argv[1])):
    if (e.get("finding") or {}).get("signature") != sig:
        continue
    node = e
    for key in path:
        if not isinstance(node, dict) or key not in node:
            sys.exit(0)
        node = node[key]
    print(node)
    break
' "$1" "$2" "$3"
}

# === 1: both stored, lineage linked ===
step "2. a predecessor and its successor, lineage linked"
CODE_OLD="$(push old "")"
[ "${CODE_OLD}" = "200" ] || die "the predecessor import failed with HTTP ${CODE_OLD}"
# The successor only links to a predecessor observed strictly earlier.
sleep 2
CODE_NEW="$(push new " AND active = ?")"
[ "${CODE_NEW}" = "200" ] || die "the successor import failed with HTTP ${CODE_NEW}"
fetch_findings "${HUB_PORT}" "${TMP_DIR}/before-purge.json" || die "the Hub refused to serve"
DEPTH_BEFORE="$(envelope_field "${TMP_DIR}/before-purge.json" "${SIG_NEW}" lineage.predecessors)"
ORIGIN_BEFORE="$(envelope_field "${TMP_DIR}/before-purge.json" "${SIG_NEW}" lineage.original_first_seen)"
COUNT_BEFORE="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "${TMP_DIR}/before-purge.json")"
if [ "${COUNT_BEFORE}" = "2" ] && [ "${DEPTH_BEFORE}" = "1" ] && [ -n "${ORIGIN_BEFORE}" ]; then
  ok "2 findings stored, the successor names 1 predecessor born at ${ORIGIN_BEFORE}"
  record "pair stored and linked" PASS "2 findings, predecessors=1"
else
  fail "expected 2 findings with predecessors=1, got ${COUNT_BEFORE} findings, predecessors='${DEPTH_BEFORE}'"
  record "pair stored and linked" FAIL "${COUNT_BEFORE} findings, predecessors='${DEPTH_BEFORE}'"
  die "nothing further is provable without the linked pair"
fi

# === 2: the boot purge drops the stale one ===
step "3. the boot purge drops the stale predecessor, keeps the fresh successor"
# Age both past the cutoff, then re-import the successor alone so its
# last_seen_ms lands inside the window again. Only then does the restart
# separate the two.
sleep "$((RETENTION_SECS + 5))"
CODE_REFRESH="$(push new " AND active = ?")"
[ "${CODE_REFRESH}" = "200" ] || die "the successor refresh failed with HTTP ${CODE_REFRESH}"
kubectl -n "${NS}" rollout restart deploy/hub >/dev/null
kubectl -n "${NS}" rollout status deploy/hub --timeout=180s >/dev/null \
  || die "the Hub did not come back after the restart"
kill "${PF_PID}" 2>/dev/null || true
PF_PID="$(forward_hub hub "${HUB_PORT}")" || true
curl -sf "http://127.0.0.1:${HUB_PORT}/health/ready" >/dev/null \
  || die "hub not reachable on ${HUB_PORT}: $(tail -3 "${TMP_DIR}/pf-hub.log" 2>&1)"
fetch_findings "${HUB_PORT}" "${TMP_DIR}/after-purge.json" || die "the Hub refused to serve after the purge"
SURVIVOR="$(envelope_field "${TMP_DIR}/after-purge.json" "${SIG_NEW}" first_seen_ms)"
PURGED="$(envelope_field "${TMP_DIR}/after-purge.json" "${SIG_OLD}" first_seen_ms)"
if [ -n "${SURVIVOR}" ] && [ -z "${PURGED}" ]; then
  ok "the predecessor is gone, the successor survived"
  record "stale row purged" PASS "predecessor purged, successor kept"
else
  fail "successor first_seen='${SURVIVOR}', predecessor first_seen='${PURGED}' (expected present, absent)"
  fail "hub log: $(kubectl -n "${NS}" logs deploy/hub --tail=5 2>&1 | tr '\n' ' ')"
  record "stale row purged" FAIL "survivor='${SURVIVOR}' purged='${PURGED}'"
fi

# === 3: the history survived its source row ===
step "4. the survivor's lineage still names the original birth"
DEPTH_AFTER="$(envelope_field "${TMP_DIR}/after-purge.json" "${SIG_NEW}" lineage.predecessors)"
ORIGIN_AFTER="$(envelope_field "${TMP_DIR}/after-purge.json" "${SIG_NEW}" lineage.original_first_seen)"
if [ "${DEPTH_AFTER}" = "${DEPTH_BEFORE}" ] && [ "${ORIGIN_AFTER}" = "${ORIGIN_BEFORE}" ]; then
  ok "lineage unchanged across the purge: origin ${ORIGIN_AFTER}, ${DEPTH_AFTER} predecessor"
  record "lineage survives the purge" PASS "origin and depth unchanged"
else
  fail "lineage moved: origin '${ORIGIN_BEFORE}' -> '${ORIGIN_AFTER}', depth '${DEPTH_BEFORE}' -> '${DEPTH_AFTER}'"
  fail "a lost origin here would mean the age of the surviving problem reset to its own first sighting"
  record "lineage survives the purge" FAIL "origin '${ORIGIN_AFTER}' depth '${DEPTH_AFTER}'"
fi

# === 4: the backup is a database, not just a file ===
step "5. backup produces a database a second Hub can serve from"
kubectl -n "${NS}" delete job hub-backup --ignore-not-found >/dev/null 2>&1 || true
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: hub-backup
  namespace: ${NS}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1654
        runAsGroup: 1654
        fsGroup: 1654
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: backup
          image: ${HUB_IMAGE}
          imagePullPolicy: Never
          args: [backup, /data/backup.db]
          env:
            - name: ASPNETCORE_ENVIRONMENT
              value: Production
          volumeMounts:
            - name: config
              mountPath: /app/appsettings.Production.json
              subPath: appsettings.Production.json
              readOnly: true
            - {name: data, mountPath: /data}
            - {name: tmp, mountPath: /tmp}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
      volumes:
        - name: config
          configMap:
            name: hub-config
            items: [{key: appsettings.Production.json, path: appsettings.Production.json}]
        - name: data
          persistentVolumeClaim: {claimName: hub-data}
        - {name: tmp, emptyDir: {}}
EOF
if kubectl -n "${NS}" wait --for=condition=complete job/hub-backup --timeout=120s >/dev/null 2>&1; then
  kubectl apply -f "${TMP_DIR}/hub.yaml.restored" >/dev/null
  if kubectl -n "${NS}" rollout status deploy/hub-restored --timeout=180s >/dev/null 2>&1; then
    PF_RESTORED_PID="$(forward_hub hub-restored "${RESTORED_PORT}")" || true
curl -sf "http://127.0.0.1:${RESTORED_PORT}/health/ready" >/dev/null \
  || die "hub-restored not reachable on ${RESTORED_PORT}: $(tail -3 "${TMP_DIR}/pf-hub-restored.log" 2>&1)"
    fetch_findings "${RESTORED_PORT}" "${TMP_DIR}/restored.json" || true
    RESTORED_ORIGIN="$(envelope_field "${TMP_DIR}/restored.json" "${SIG_NEW}" lineage.original_first_seen 2>/dev/null || true)"
  else
    RESTORED_ORIGIN=""
    fail "the restored Hub never became ready: $(kubectl -n "${NS}" logs deploy/hub-restored --tail=10 2>&1 | tr '\n' ' ')"
  fi
else
  RESTORED_ORIGIN=""
  fail "the backup job did not complete: $(kubectl -n "${NS}" logs job/hub-backup --tail=10 2>&1 | tr '\n' ' ')"
fi
if [ -n "${RESTORED_ORIGIN}" ] && [ "${RESTORED_ORIGIN}" = "${ORIGIN_AFTER}" ]; then
  ok "a second Hub opened the backup and served the survivor with its lineage intact"
  record "backup is servable" PASS "restored origin matches"
else
  fail "the restored Hub served origin '${RESTORED_ORIGIN}', expected '${ORIGIN_AFTER}'"
  record "backup is servable" FAIL "restored origin '${RESTORED_ORIGIN}'"
fi

step "Report"
{
  echo "# ${SCENARIO}"
  echo
  echo "| sub-test | verdict | note |"
  echo "|---|---|---|"
  for i in "${!NAMES[@]}"; do
    echo "| ${NAMES[$i]} | ${VERDICTS[$i]} | ${NOTES[$i]} |"
  done
} > "${REPORT}"
step "Report written to ${REPORT}"

for v in "${VERDICTS[@]}"; do
  [ "${v}" = "PASS" ] || { color_red "SCENARIO FAILED"; exit 1; }
done
color_green "SCENARIO PASSED"
