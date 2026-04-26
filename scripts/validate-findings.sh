#!/usr/bin/env bash
# Drive the 10 k6 anti-pattern scenarios in sequence and assert that
# perf-sentinel produces at least one finding of the expected type on
# the expected service per scenario. Writes tmp/validation-report.md
# and prints a summary table. Exit code 0 if all 10 pass, 1 otherwise.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

DAEMON_URL="${DAEMON_URL:-http://localhost:14318}"
NAMESPACE="${NAMESPACE:-shop}"
K6_IMAGE="${K6_IMAGE:-grafana/k6:0.55.0}"
TMP_DIR="${REPO_ROOT}/tmp"
REPORT="${TMP_DIR}/validation-report.md"
mkdir -p "${TMP_DIR}"

color_blue()   { printf "\033[34m%s\033[0m\n" "$*"; }
color_green()  { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()    { printf "\033[31m%s\033[0m\n" "$*"; }
color_yellow() { printf "\033[33m%s\033[0m\n" "$*"; }

# scenario_name : finding_type : expected_service : k6_file
SCENARIOS=(
    "n-plus-one-sql:n_plus_one_sql:order-service:scenarios/n-plus-one-sql.js"
    "n-plus-one-http:n_plus_one_http:notification-service:scenarios/n-plus-one-http.js"
    "redundant-sql:redundant_sql:payment-service:scenarios/redundant-sql.js"
    "redundant-http:redundant_http:order-service:scenarios/redundant-http.js"
    "slow-sql:slow_sql:order-service:scenarios/slow-sql.js"
    "slow-http:slow_http:payment-service:scenarios/slow-http.js"
    "fanout:excessive_fanout:notification-service:scenarios/fanout.js"
    "chatty:chatty_service:notification-service:scenarios/chatty.js"
    "pool-saturation:pool_saturation:order-service:scenarios/pool-saturation.js"
    "serialized:serialized_calls:notification-service:scenarios/serialized.js"
)

declare -a RESULTS

run_scenario() {
    local name="$1" finding_type="$2" service="$3" file="$4"

    color_blue "==> ${name} (expects type=${finding_type} service=${service})"

    kubectl -n "${NAMESPACE}" create configmap "k6-scenario-${name}" \
        --from-file=scenario.js="${file}" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: k6-${name}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/component: k6
    perfsim.antiPattern: "${finding_type}"
spec:
  ttlSecondsAfterFinished: 300
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
          args: ["run", "--quiet", "/scripts/scenario.js"]
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
            name: k6-scenario-${name}
EOF

    if kubectl -n "${NAMESPACE}" wait "job/k6-${name}" \
            --for=condition=Complete --timeout=120s >/dev/null 2>&1; then
        color_green "    k6 job completed"
    else
        color_red "    k6 job did not complete in 120s"
        RESULTS+=("FAIL|${name}|${finding_type}|${service}|0|k6 job timeout")
        kubectl -n "${NAMESPACE}" delete "job/k6-${name}" --ignore-not-found >/dev/null
        kubectl -n "${NAMESPACE}" delete "configmap/k6-scenario-${name}" --ignore-not-found >/dev/null
        return
    fi

    color_blue "    waiting 15s for daemon to flush traces"
    sleep 15

    local findings_json count note=""
    if ! findings_json="$(curl -fsS "${DAEMON_URL}/api/findings" 2>&1)"; then
        color_red "    FAIL (daemon /api/findings unreachable)"
        RESULTS+=("FAIL|${name}|${finding_type}|${service}|0|daemon /api/findings unreachable")
        kubectl -n "${NAMESPACE}" delete "job/k6-${name}" --ignore-not-found >/dev/null
        kubectl -n "${NAMESPACE}" delete "configmap/k6-scenario-${name}" --ignore-not-found >/dev/null
        return
    fi

    count="$(printf "%s" "${findings_json}" | EXPECTED_TYPE="${finding_type}" \
            EXPECTED_SERVICE="${service}" python3 -c "
import json, os, sys
try:
    items = json.load(sys.stdin)
except json.JSONDecodeError:
    print(-1)
    sys.exit(0)
expected_type = os.environ['EXPECTED_TYPE']
expected_service = os.environ['EXPECTED_SERVICE']
def unwrap(it):
    return it.get('finding', it) if isinstance(it, dict) else {}
matched = [f for it in items if (f := unwrap(it)).get('type') == expected_type and f.get('service') == expected_service]
print(len(matched))
" 2>/dev/null || echo -1)"

    if [ "${count}" = "-1" ]; then
        color_red "    FAIL (daemon returned malformed JSON)"
        RESULTS+=("FAIL|${name}|${finding_type}|${service}|0|daemon returned malformed JSON")
    elif [ "${count:-0}" -ge 1 ]; then
        color_green "    PASS (${count} matching findings)"
        RESULTS+=("PASS|${name}|${finding_type}|${service}|${count}|")
    else
        color_red "    FAIL (0 matching findings)"
        RESULTS+=("FAIL|${name}|${finding_type}|${service}|0|no matching finding within 15s of job completion")
    fi

    kubectl -n "${NAMESPACE}" delete "job/k6-${name}" --ignore-not-found >/dev/null
    kubectl -n "${NAMESPACE}" delete "configmap/k6-scenario-${name}" --ignore-not-found >/dev/null
}

print_summary() {
    local pass=0 fail=0
    {
        echo "# perf-sentinel S2 validation report"
        echo
        echo "Run: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "Daemon: ${DAEMON_URL}"
        echo
        echo "| Result | Scenario | Finding type | Service | Count | Note |"
        echo "| --- | --- | --- | --- | --- | --- |"
    } > "${REPORT}"

    echo
    color_blue "=== perf-sentinel S2 validation results ==="
    printf "%-6s %-18s %-22s %-22s %-7s %s\n" "STATUS" "SCENARIO" "TYPE" "SERVICE" "COUNT" "NOTE"

    for line in "${RESULTS[@]}"; do
        IFS='|' read -r status name ftype svc count note <<<"${line}"
        if [ "${status}" = "PASS" ]; then
            pass=$((pass + 1))
            printf "\033[32m%-6s\033[0m %-18s %-22s %-22s %-7s %s\n" "${status}" "${name}" "${ftype}" "${svc}" "${count}" "${note}"
        else
            fail=$((fail + 1))
            printf "\033[31m%-6s\033[0m %-18s %-22s %-22s %-7s %s\n" "${status}" "${name}" "${ftype}" "${svc}" "${count}" "${note}"
        fi
        echo "| ${status} | ${name} | ${ftype} | ${svc} | ${count} | ${note} |" >> "${REPORT}"
    done

    {
        echo
        echo "## Score"
        echo
        echo "${pass} PASS / $((pass + fail)) anti-patterns detected."
    } >> "${REPORT}"

    echo
    color_blue "Score: ${pass} / $((pass + fail)) anti-patterns detected"
    color_blue "Report: ${REPORT}"

    if [ "${fail}" -gt 0 ]; then
        return 1
    fi
    return 0
}

main() {
    if ! curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1; then
        color_red "daemon not reachable at ${DAEMON_URL}, run make up first"
        exit 1
    fi
    if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
        color_red "namespace ${NAMESPACE} missing, run make seed-services first"
        exit 1
    fi

    for spec in "${SCENARIOS[@]}"; do
        IFS=':' read -r name ftype svc file <<<"${spec}"
        run_scenario "${name}" "${ftype}" "${svc}" "${file}"
    done

    print_summary
}

main "$@"
