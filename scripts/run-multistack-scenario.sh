#!/usr/bin/env bash
# Drive the 10 multistack k6 sub-scenarios for <stack> SEQUENTIALLY,
# one per anti-pattern, polling /api/findings after each so the daemon
# snapshot is captured before the trace_ttl_ms (5s in this lab) evicts
# the finding. Mirrors the per-scenario flow of scripts/validate-findings.sh
# (Java baseline) but reuses the single composite scenario file at
# scenarios/<stack>-svc-validation.js — each sub-run picks one exported
# function via `k6 run --exec <fn>` so we do NOT need 10 separate k6 files
# per stack.
#
# Usage:  ./scripts/run-multistack-scenario.sh <stack>
# Example: ./scripts/run-multistack-scenario.sh quarkus
#
# Exit code: 0 if all 10 anti-patterns produce at least one finding
# tagged service=<stack>-svc, 1 otherwise. Writes
# tmp/validation-report-<stack>-svc.md.
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $(basename "$0") <stack>" >&2
    echo "       e.g. $(basename "$0") quarkus" >&2
    exit 2
fi

STACK="$1"
SERVICE="${STACK}-svc"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

SCENARIO_FILE="scenarios/${SERVICE}-validation.js"
if [ ! -f "${SCENARIO_FILE}" ]; then
    echo "scenario file ${SCENARIO_FILE} missing" >&2
    exit 1
fi

NAMESPACE="${NAMESPACE:-shop}"
K6_IMAGE="${K6_IMAGE:-grafana/k6:1.7.1}"
DAEMON_URL="${DAEMON_URL:-http://localhost:14318}"
TMP_DIR="${REPO_ROOT}/tmp"
REPORT="${TMP_DIR}/validation-report-${SERVICE}.md"
mkdir -p "${TMP_DIR}"

color_blue()   { printf "\033[34m%s\033[0m\n" "$*"; }
color_green()  { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()    { printf "\033[31m%s\033[0m\n" "$*"; }
color_yellow() { printf "\033[33m%s\033[0m\n" "$*"; }

# anti_pattern_type : vus : duration
# Order matches docs/MULTISTACK.md. The scenario file dispatches on
# __ENV.ANTI_PATTERN to the matching function, so the type itself
# doubles as the env var value (k6 1.x has no --exec CLI flag).
ANTI_PATTERNS=(
    "n_plus_one_sql:5:30s"
    "n_plus_one_http:5:30s"
    "redundant_sql:5:30s"
    "redundant_http:5:30s"
    "slow_sql:3:30s"
    "slow_http:3:30s"
    "excessive_fanout:3:30s"
    "chatty_service:3:30s"
    "serialized_calls:3:30s"
    "pool_saturation:2:30s"
)

declare -a RESULTS

probe_daemon() {
    local max_attempts=5 sleep_s=2 attempt=1
    while [ "${attempt}" -le "${max_attempts}" ]; do
        if curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1; then
            return 0
        fi
        if [ "${attempt}" -eq "${max_attempts}" ]; then
            color_red "daemon not reachable at ${DAEMON_URL} after ${max_attempts} attempts, run scripts/port-forward.sh start"
            exit 1
        fi
        color_yellow "daemon probe attempt ${attempt}/${max_attempts} failed, retrying in ${sleep_s}s"
        sleep "${sleep_s}"
        attempt=$((attempt + 1))
    done
}

count_findings_for() {
    local pattern="$1" findings_json="$2"
    printf "%s" "${findings_json}" \
        | EXPECTED_TYPE="${pattern}" EXPECTED_SERVICE="${SERVICE}" python3 -c "
import json, os, sys
try:
    items = json.load(sys.stdin)
except json.JSONDecodeError:
    print(-1); sys.exit(0)
expected_type = os.environ['EXPECTED_TYPE']
expected_service = os.environ['EXPECTED_SERVICE']
def unwrap(it):
    return it.get('finding', it) if isinstance(it, dict) else {}
matched = [
    f for it in items
    if (f := unwrap(it)).get('type') == expected_type
    and f.get('service') == expected_service
]
print(len(matched))
" 2>/dev/null || echo -1
}

run_one() {
    local pattern="$1" vus="$2" duration="$3"
    local job_name="k6-${SERVICE}-${pattern//_/-}"
    local cm_name="k6-${SERVICE}-script"

    color_blue "==> ${pattern} (vus=${vus} duration=${duration})"

    kubectl -n "${NAMESPACE}" create configmap "${cm_name}" \
        --from-file=scenario.js="${SCENARIO_FILE}" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/component: k6
    perfsim.stack: "${STACK}"
    perfsim.antiPattern: "${pattern}"
spec:
  ttlSecondsAfterFinished: 120
  backoffLimit: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/component: k6
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: ${K6_IMAGE}
          env:
            - name: ANTI_PATTERN
              value: "${pattern}"
          args:
            - run
            - --quiet
            - --vus
            - "${vus}"
            - --duration
            - "${duration}"
            - /scripts/scenario.js
          volumeMounts:
            - name: script
              mountPath: /scripts
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
      volumes:
        - name: script
          configMap:
            name: ${cm_name}
EOF

    if kubectl -n "${NAMESPACE}" wait "job/${job_name}" \
            --for=condition=Complete --timeout=120s >/dev/null 2>&1; then
        color_green "    k6 job completed"
    else
        color_red "    k6 job did not complete in 120s"
        RESULTS+=("FAIL|${pattern}|0|k6 job timeout")
        kubectl -n "${NAMESPACE}" delete "job/${job_name}" --ignore-not-found >/dev/null
        return
    fi

    color_blue "    waiting 15s for daemon to flush traces"
    sleep 15

    local findings_json count
    if ! findings_json="$(curl -fsS "${DAEMON_URL}/api/findings" 2>&1)"; then
        color_red "    FAIL (daemon /api/findings unreachable)"
        RESULTS+=("FAIL|${pattern}|0|daemon /api/findings unreachable")
        kubectl -n "${NAMESPACE}" delete "job/${job_name}" --ignore-not-found >/dev/null
        return
    fi
    count="$(count_findings_for "${pattern}" "${findings_json}")"

    if [ "${count}" = "-1" ]; then
        color_red "    FAIL (daemon returned malformed JSON)"
        RESULTS+=("FAIL|${pattern}|0|daemon returned malformed JSON")
    elif [ "${count:-0}" -ge 1 ]; then
        color_green "    PASS (${count} matching findings)"
        RESULTS+=("PASS|${pattern}|${count}|")
    else
        color_red "    FAIL (0 matching findings)"
        RESULTS+=("FAIL|${pattern}|0|no finding of this type tagged service=${SERVICE}")
    fi

    kubectl -n "${NAMESPACE}" delete "job/${job_name}" --ignore-not-found >/dev/null
}

print_summary() {
    local pass=0 fail=0
    {
        echo "# multistack validation report — ${SERVICE}"
        echo
        echo "Run: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "Daemon: ${DAEMON_URL}"
        echo
        echo "| Result | Anti-pattern | Count | Note |"
        echo "| --- | --- | --- | --- |"
    } > "${REPORT}"

    echo
    color_blue "=== multistack validation results — ${SERVICE} ==="
    printf "%-6s %-22s %-7s %s\n" "STATUS" "ANTI-PATTERN" "COUNT" "NOTE"

    for line in "${RESULTS[@]}"; do
        IFS='|' read -r status ftype count note <<<"${line}"
        if [ "${status}" = "PASS" ]; then
            pass=$((pass + 1))
            printf "\033[32m%-6s\033[0m %-22s %-7s %s\n" "${status}" "${ftype}" "${count}" "${note}"
        else
            fail=$((fail + 1))
            printf "\033[31m%-6s\033[0m %-22s %-7s %s\n" "${status}" "${ftype}" "${count}" "${note}"
        fi
        echo "| ${status} | ${ftype} | ${count} | ${note} |" >> "${REPORT}"
    done

    {
        echo
        echo "## Score"
        echo
        echo "${pass} PASS / $((pass + fail)) anti-patterns detected for ${SERVICE}."
    } >> "${REPORT}"

    echo
    color_blue "Score: ${pass} / $((pass + fail)) anti-patterns detected for ${SERVICE}"
    color_blue "Report: ${REPORT}"

    [ "${fail}" -gt 0 ] && return 1
    return 0
}

probe_daemon
for spec in "${ANTI_PATTERNS[@]}"; do
    IFS=':' read -r pattern vus duration <<<"${spec}"
    run_one "${pattern}" "${vus}" "${duration}"
done
# Cleanup the shared ConfigMap.
kubectl -n "${NAMESPACE}" delete "configmap/k6-${SERVICE}-script" --ignore-not-found >/dev/null
print_summary
