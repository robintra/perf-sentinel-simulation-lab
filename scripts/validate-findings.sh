#!/usr/bin/env bash
# Drive the 12 k6 anti-pattern scenarios in sequence and assert that
# perf-sentinel produces at least one finding of the expected type on
# the expected service per scenario. Writes tmp/validation-report.md
# and prints a summary table. Exit code 0 if all 12 pass, 1 otherwise.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

DAEMON_URL="${DAEMON_URL:-http://localhost:14318}"
NAMESPACE="${NAMESPACE:-shop}"
K6_IMAGE="${K6_IMAGE:-grafana/k6:1.7.1}"
TMP_DIR="${REPO_ROOT}/tmp"
REPORT="${TMP_DIR}/validation-report.md"
mkdir -p "${TMP_DIR}"

color_blue()   { printf "\033[34m%s\033[0m\n" "$*"; }
color_green()  { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()    { printf "\033[31m%s\033[0m\n" "$*"; }
color_yellow() { printf "\033[33m%s\033[0m\n" "$*"; }

# scenario_name : finding_type : expected_service : k6_file : source_endpoint
SCENARIOS=(
    "n-plus-one-sql:n_plus_one_sql:order-service:scenarios/n-plus-one-sql.js:/api/fault/n-plus-one-sql"
    "n-plus-one-http:n_plus_one_http:notification-service:scenarios/n-plus-one-http.js:/api/fault/n-plus-one-http"
    "redundant-sql:redundant_sql:payment-service:scenarios/redundant-sql.js:/api/fault/redundant-sql"
    "redundant-http:redundant_http:order-service:scenarios/redundant-http.js:/api/fault/redundant-http"
    "slow-sql:slow_sql:order-service:scenarios/slow-sql.js:/api/fault/slow-sql"
    "slow-http:slow_http:payment-service:scenarios/slow-http.js:/api/fault/slow-http"
    "fanout:excessive_fanout:notification-service:scenarios/fanout.js:/api/fault/fanout"
    "chatty:chatty_service:notification-service:scenarios/chatty.js:/api/fault/chatty"
    "pool-saturation:pool_saturation:order-service:scenarios/pool-saturation.js:/api/fault/pool-saturation"
    "serialized:serialized_calls:notification-service:scenarios/serialized.js:/api/fault/serialized"
    "n-plus-one-messaging:n_plus_one_messaging:order-service:scenarios/n-plus-one-messaging.js:/api/fault/n-plus-one-messaging"
    "slow-messaging:slow_messaging:order-service:scenarios/slow-messaging.js:/api/fault/slow-messaging"
)

declare -a RESULTS

wait_for_job() {
    local job_name="$1" complete_flag failed_flag complete_pid failed_pid
    complete_flag="${TMP_DIR}/${job_name}-complete"
    failed_flag="${TMP_DIR}/${job_name}-failed"
    rm -f "${complete_flag}" "${failed_flag}"
    (kubectl -n "${NAMESPACE}" wait "job/${job_name}" --for=condition=Complete --timeout=120s >/dev/null 2>&1 \
        && : > "${complete_flag}") &
    complete_pid=$!
    (kubectl -n "${NAMESPACE}" wait "job/${job_name}" --for=condition=Failed --timeout=120s >/dev/null 2>&1 \
        && : > "${failed_flag}") &
    failed_pid=$!

    while true; do
        if [ -f "${complete_flag}" ]; then
            JOB_STATE=Complete
            break
        fi
        if [ -f "${failed_flag}" ]; then
            JOB_STATE=Failed
            break
        fi
        if ! kill -0 "${complete_pid}" 2>/dev/null && ! kill -0 "${failed_pid}" 2>/dev/null; then
            JOB_STATE=Timeout
            break
        fi
        sleep 1
    done

    kill "${complete_pid}" "${failed_pid}" 2>/dev/null || true
    wait "${complete_pid}" "${failed_pid}" 2>/dev/null || true
    rm -f "${complete_flag}" "${failed_flag}"
    [ "${JOB_STATE}" = Complete ]
}

run_scenario() {
    local name="$1" finding_type="$2" service="$3" file="$4" endpoint="$5"
    local baseline_file="${TMP_DIR}/k6-${name}-baseline-trace-ids.json"
    local started_at_ms

    color_blue "==> ${name} (expects type=${finding_type} service=${service} endpoint=${endpoint})"

    if ! curl --connect-timeout 3 --max-time 10 -fsS "${DAEMON_URL}/api/findings?limit=10000&include_acked=true" \
            | python3 -c '
import json, sys
items = json.load(sys.stdin)
def unwrap(item):
    if not isinstance(item, dict):
        raise TypeError
    finding = item.get("finding", item)
    if not isinstance(finding, dict):
        raise TypeError
    return finding
if not isinstance(items, list):
    raise TypeError
print(json.dumps(sorted({f["trace_id"] for item in items if (f := unwrap(item)).get("trace_id")})))
' > "${baseline_file}"; then
        color_red "    FAIL (could not snapshot existing daemon trace IDs)"
        RESULTS+=("FAIL|${name}|${finding_type}|${service}|0|could not snapshot existing daemon trace IDs")
        rm -f "${baseline_file}"
        return
    fi
    started_at_ms="$(python3 -c 'import time; print(time.time_ns() // 1_000_000)')"

    kubectl -n "${NAMESPACE}" delete "job/k6-${name}" \
        --ignore-not-found --wait=true >/dev/null

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

    JOB_STATE=""
    if wait_for_job "k6-${name}"; then
        color_green "    k6 job completed"
    else
        if [ "${JOB_STATE}" = Failed ]; then
            color_red "    k6 Job Failed; logs follow"
            kubectl -n "${NAMESPACE}" logs "job/k6-${name}" --all-containers=true --tail=100 >&2 || true
            RESULTS+=("FAIL|${name}|${finding_type}|${service}|0|k6 Job Failed condition")
        else
            color_red "    k6 job did not complete in 120s"
            RESULTS+=("FAIL|${name}|${finding_type}|${service}|0|k6 job timeout")
        fi
        kubectl -n "${NAMESPACE}" delete "job/k6-${name}" --ignore-not-found >/dev/null
        kubectl -n "${NAMESPACE}" delete "configmap/k6-scenario-${name}" --ignore-not-found >/dev/null
        rm -f "${baseline_file}"
        return
    fi

    color_blue "    waiting 15s, then polling findings up to 6 times every 5s (40s deadline)"
    sleep 15

    local findings_json count note="" attempt
    for attempt in 1 2 3 4 5 6; do
        if ! findings_json="$(curl --connect-timeout 3 --max-time 10 -fsS "${DAEMON_URL}/api/findings?limit=10000&include_acked=true" 2>&1)"; then
            color_red "    FAIL (daemon /api/findings unreachable)"
            RESULTS+=("FAIL|${name}|${finding_type}|${service}|0|daemon /api/findings unreachable")
            break
        fi

        count="$(printf "%s" "${findings_json}" | EXPECTED_TYPE="${finding_type}" \
            EXPECTED_SERVICE="${service}" EXPECTED_ENDPOINT="${endpoint}" \
            BASELINE_FILE="${baseline_file}" STARTED_AT_MS="${started_at_ms}" python3 -c "
import json, os, sys
try:
    items = json.load(sys.stdin)
    with open(os.environ['BASELINE_FILE']) as stream:
        baseline_trace_ids = set(json.load(stream))
    if not isinstance(items, list):
        raise TypeError
except (json.JSONDecodeError, OSError, TypeError, ValueError):
    print(-1)
    sys.exit(0)
expected_type = os.environ['EXPECTED_TYPE']
expected_service = os.environ['EXPECTED_SERVICE']
expected_endpoint = os.environ['EXPECTED_ENDPOINT']
started_at_ms = int(os.environ['STARTED_AT_MS'])
def unwrap(it):
    if not isinstance(it, dict):
        raise TypeError
    finding = it.get('finding', it)
    if not isinstance(finding, dict):
        raise TypeError
    return finding
try:
    matched = [f for it in items if (f := unwrap(it)).get('type') == expected_type
               and f.get('service') == expected_service
               and f.get('source_endpoint') == expected_endpoint
               and f.get('trace_id') not in baseline_trace_ids
               and isinstance(it.get('stored_at_ms'), (int, float))
               and it['stored_at_ms'] > started_at_ms]
except TypeError:
    print(-1)
    sys.exit(0)
print(len(matched))
" 2>/dev/null || echo -1)"

        if [ "${count}" = "-1" ]; then
            color_red "    FAIL (daemon returned malformed JSON)"
            RESULTS+=("FAIL|${name}|${finding_type}|${service}|0|daemon returned malformed JSON")
            break
        elif [ "${count:-0}" -ge 1 ]; then
            color_green "    PASS (${count} matching findings on probe ${attempt}/6)"
            RESULTS+=("PASS|${name}|${finding_type}|${service}|${count}|")
            break
        elif [ "${attempt}" -eq 6 ]; then
            color_red "    FAIL (0 matching findings by the 40s deadline)"
            RESULTS+=("FAIL|${name}|${finding_type}|${service}|0|no fresh endpoint-matched finding within 40s of job completion")
        else
            color_yellow "    no match on probe ${attempt}/6; retrying in 5s"
            sleep 5
        fi
    done

    kubectl -n "${NAMESPACE}" delete "job/k6-${name}" --ignore-not-found >/dev/null
    kubectl -n "${NAMESPACE}" delete "configmap/k6-scenario-${name}" --ignore-not-found >/dev/null
    rm -f "${baseline_file}"
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
    local max_probe_attempts=5 probe_sleep_s=2 attempt=1
    while [ "${attempt}" -le "${max_probe_attempts}" ]; do
        if curl --connect-timeout 3 --max-time 10 -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1; then
            break
        fi
        if [ "${attempt}" -eq "${max_probe_attempts}" ]; then
            color_red "daemon not reachable at ${DAEMON_URL} after ${max_probe_attempts} attempts, run make up first"
            exit 1
        fi
        color_yellow "daemon probe attempt ${attempt}/${max_probe_attempts} failed, retrying in ${probe_sleep_s}s"
        sleep "${probe_sleep_s}"
        attempt=$((attempt + 1))
    done
    if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
        color_red "namespace ${NAMESPACE} missing, run make seed-services first"
        exit 1
    fi

    for spec in "${SCENARIOS[@]}"; do
        IFS=':' read -r name ftype svc file endpoint <<<"${spec}"
        run_scenario "${name}" "${ftype}" "${svc}" "${file}" "${endpoint}"
    done

    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
