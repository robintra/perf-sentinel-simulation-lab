#!/usr/bin/env bash
# Run the strict twelve-finding multistack contract or the focused RabbitMQ pair.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "usage: $(basename "$0") <stack> [messaging]" >&2
    exit 2
fi

STACK="$1"
MODE="${2:-default}"
if [ "${MODE}" != "default" ] && [ "${MODE}" != "messaging" ]; then
    echo "unknown mode: ${MODE} (expected default or messaging)" >&2
    exit 2
fi

SERVICE="${STACK}-svc"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
SCENARIO_FILE="scenarios/${SERVICE}-validation.js"
[ -f "${SCENARIO_FILE}" ] || { echo "scenario file ${SCENARIO_FILE} missing" >&2; exit 1; }

NAMESPACE="${NAMESPACE:-shop}"
K6_IMAGE="${K6_IMAGE:-grafana/k6:1.7.1}"
DAEMON_URL="${DAEMON_URL:-http://localhost:14318}"
TMP_DIR="${VALIDATION_TMP_DIR:-${REPO_ROOT}/tmp}"
REPORT="${TMP_DIR}/validation-report-${SERVICE}.md"
if [ "${MODE}" = messaging ]; then
    REPORT="${TMP_DIR}/validation-report-${SERVICE}-messaging.md"
fi
mkdir -p "${TMP_DIR}"

color_blue() { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red() { printf "\033[31m%s\033[0m\n" "$*"; }
color_yellow() { printf "\033[33m%s\033[0m\n" "$*"; }

daemon_curl() {
    curl --connect-timeout 3 --max-time 10 "$@"
}

ANTI_PATTERNS=(
    "n_plus_one_sql:5:30s"
    "n_plus_one_http:5:30s"
    "n_plus_one_messaging:5:30s"
    "redundant_sql:5:30s"
    "redundant_http:5:30s"
    "slow_sql:3:30s"
    "slow_http:3:30s"
    "slow_messaging:1:15s"
    "excessive_fanout:3:30s"
    "chatty_service:3:30s"
    "serialized_calls:3:30s"
    "pool_saturation:2:30s"
)
if [ "${MODE}" = messaging ]; then
    ANTI_PATTERNS=("n_plus_one_messaging:5:30s" "slow_messaging:1:15s")
fi
# ONLY_PATTERNS="redundant_http:5:30s" replays a subset after a CI failure instead of
# paying for the full twelve (issue #101). Space-separated, same pattern:vus:duration form.
if [ -n "${ONLY_PATTERNS:-}" ]; then
    read -ra ANTI_PATTERNS <<<"${ONLY_PATTERNS}"
fi
declare -a RESULTS

. "${REPO_ROOT}/scripts/framework-expectation.sh"

endpoint_for() {
    case "$1" in
        n_plus_one_sql) echo /api/fault/n-plus-one-sql ;;
        n_plus_one_http) echo /api/fault/n-plus-one-http ;;
        redundant_sql) echo /api/fault/redundant-sql ;;
        redundant_http) echo /api/fault/redundant-http ;;
        slow_sql) echo /api/fault/slow-sql ;;
        slow_http) echo /api/fault/slow-http ;;
        excessive_fanout) echo /api/fault/fanout ;;
        chatty_service) echo /api/fault/chatty ;;
        serialized_calls) echo /api/fault/serialized ;;
        pool_saturation) echo /api/fault/pool-saturation ;;
        n_plus_one_messaging) echo /api/fault/n-plus-one-messaging ;;
        slow_messaging) echo /api/fault/slow-messaging ;;
        *) return 1 ;;
    esac
}

probe_daemon() {
    local attempt=1
    while [ "${attempt}" -le 5 ]; do
        daemon_curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 && return
        [ "${attempt}" -eq 5 ] && { color_red "daemon not reachable at ${DAEMON_URL}"; exit 1; }
        color_yellow "daemon probe attempt ${attempt}/5 failed"
        sleep 2
        attempt=$((attempt + 1))
    done
}

snapshot_pairs() {
    daemon_curl -fsS "${DAEMON_URL}/api/findings?limit=10000&include_acked=true" | python3 -c '
import json, sys
items = json.load(sys.stdin)
if not isinstance(items, list):
    raise SystemExit("daemon findings response must be a list")
def unwrap(item):
    if not isinstance(item, dict):
        raise TypeError("daemon finding item must be an object")
    finding = item.get("finding", item)
    if not isinstance(finding, dict):
        raise TypeError("daemon finding wrapper must contain an object")
    return finding
try:
    findings = [unwrap(item) for item in items]
except TypeError as error:
    raise SystemExit(str(error))
print(json.dumps(sorted({(f["trace_id"], f.get("source_endpoint") or "") for f in findings if f.get("trace_id")})))
'
}

evaluate_findings() {
    local pattern="$1" endpoint="$2" baseline_file="$3" started_at_ms="$4" expected_framework="$5" expected_recommendation="$6" findings_json="$7"
    printf '%s' "${findings_json}" | EXPECTED_TYPE="${pattern}" EXPECTED_SERVICE="${SERVICE}" \
        EXPECTED_ENDPOINT="${endpoint}" EXPECTED_FRAMEWORK="${expected_framework}" EXPECTED_RECOMMENDATION="${expected_recommendation}" BASELINE_FILE="${baseline_file}" STARTED_AT_MS="${started_at_ms}" \
        python3 -c '
import json, os, sys
try:
    items = json.load(sys.stdin)
    baseline_pairs = json.load(open(os.environ["BASELINE_FILE"]))
    if not isinstance(items, list) or not isinstance(baseline_pairs, list):
        raise ValueError
    def unwrap(item):
        if not isinstance(item, dict):
            raise ValueError
        finding = item.get("finding", item)
        if not isinstance(finding, dict):
            raise ValueError
        return finding
    records = [(item, unwrap(item)) for item in items]
    baseline_trace_ids = {pair[0] for pair in baseline_pairs if isinstance(pair, list) and pair}
except (json.JSONDecodeError, OSError, TypeError, ValueError):
    print("-1|malformed findings or baseline")
    raise SystemExit
kind, service, endpoint = (os.environ[k] for k in ("EXPECTED_TYPE", "EXPECTED_SERVICE", "EXPECTED_ENDPOINT"))
framework, recommendation = (os.environ[k] for k in ("EXPECTED_FRAMEWORK", "EXPECTED_RECOMMENDATION"))
expected_destination = "rabbitmq perfsim." + service
started = int(os.environ["STARTED_AT_MS"])
def fresh(item, finding):
    trace = finding.get("trace_id")
    return bool(finding.get("type") == kind and finding.get("service") == service and finding.get("source_endpoint") == endpoint and trace and trace not in baseline_trace_ids and isinstance(item.get("stored_at_ms"), (int, float)) and item["stored_at_ms"] > started)
def match(item, finding):
    if not fresh(item, finding):
        return False
    if framework:
        suggestion = finding.get("suggested_fix") or {}
        if suggestion.get("framework") != framework:
            return False
        if recommendation and not any(value in (suggestion.get("recommendation") or "") for value in recommendation.split("||")):
            return False
    pattern = finding.get("pattern") or {}
    if kind == "n_plus_one_messaging":
        return pattern.get("template") == expected_destination and pattern.get("occurrences", 0) >= 8
    if kind == "slow_messaging":
        return pattern.get("template") == expected_destination and pattern.get("occurrences", 0) >= 3 and pattern.get("span_duration_us_p50", 0) > 500000
    return True
matched = [finding for item, finding in records if match(item, finding)]
if not matched:
    # A fresh finding that failed only the framework/pattern assertions used to report the
    # same "nothing arrived" message, which is indistinguishable in CI logs (issue #101).
    rejected = [finding for item, finding in records if fresh(item, finding)]
    if rejected:
        suggestion = rejected[0].get("suggested_fix") or {}
        # `|` is both the field separator here and the markdown column separator downstream.
        print("0|" + ("fresh finding rejected: framework=%s (want %s) recommendation=%s pattern=%s" % (
            suggestion.get("framework"), framework or "-",
            json.dumps(suggestion.get("recommendation") or "")[:80],
            json.dumps(rejected[0].get("pattern") or {})[:120])).replace("|", "/"))
    else:
        # Distinguish "the daemon never produced it" from "it was there but not fresh"
        # (pre-existing trace id, or stored before the k6 job started).
        same = [item for item, finding in records if finding.get("type") == kind and finding.get("service") == service and finding.get("source_endpoint") == endpoint]
        print("0|no fresh type/service/source finding (same type+service+source in store: %d)" % len(same))
else:
    finding = matched[0]
    pattern = finding.get("pattern") or {}
    note = "trace=%s source=%s" % (finding["trace_id"], finding["source_endpoint"])
    if kind in ("n_plus_one_messaging", "slow_messaging"):
        note += " destination=%s occurrences=%s p50_us=%s" % (pattern.get("template"), pattern.get("occurrences"), pattern.get("span_duration_us_p50", "n/a"))
    print("%d|%s" % (len(matched), note))
'
}

cleanup_one() {
    kubectl -n "${NAMESPACE}" delete "job/$1" --ignore-not-found >/dev/null
}

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

run_one() {
    local pattern="$1" vus="$2" duration="$3" endpoint job_name cm_name baseline_file started_at_ms findings_json evaluation count note expectation expected_framework expected_recommendation attempt attempts
    endpoint="$(endpoint_for "${pattern}")"
    expectation="$(framework_expectation "${STACK}" "${pattern}")"
    expected_framework="${expectation%%|*}"
    expected_recommendation="${expectation#*|}"
    [ "${expectation}" = "${expected_framework}" ] && expected_recommendation=""
    job_name="k6-${SERVICE}-${pattern//_/-}"
    cm_name="k6-${SERVICE}-script"
    baseline_file="${TMP_DIR}/${job_name}-baseline-pairs.json"
    color_blue "==> ${pattern} (vus=${vus} duration=${duration} endpoint=${endpoint})"

    if ! snapshot_pairs > "${baseline_file}"; then
        RESULTS+=("FAIL|${pattern}|0|could not snapshot trace/source pairs")
        return
    fi
    started_at_ms="$(python3 -c 'import time; print(time.time_ns() // 1_000_000)')"
    cleanup_one "${job_name}"
    kubectl -n "${NAMESPACE}" create configmap "${cm_name}" --from-file=scenario.js="${SCENARIO_FILE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${NAMESPACE}
spec:
  ttlSecondsAfterFinished: 120
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: ${K6_IMAGE}
          env:
            - name: ANTI_PATTERN
              value: "${pattern}"
          args: ["run", "--quiet", "--vus", "${vus}", "--duration", "${duration}", "/scripts/scenario.js"]
          volumeMounts:
            - name: script
              mountPath: /scripts
      volumes:
        - name: script
          configMap:
            name: ${cm_name}
EOF
    JOB_STATE=""
    if ! wait_for_job "${job_name}"; then
        if [ "${JOB_STATE}" = Failed ]; then
            color_red "    k6 Job Failed; logs follow"
            kubectl -n "${NAMESPACE}" logs "job/${job_name}" --all-containers=true --tail=100 >&2 || true
            RESULTS+=("FAIL|${pattern}|0|k6 Job Failed condition")
        else
            color_red "    k6 job timed out; logs follow"
            kubectl -n "${NAMESPACE}" logs "job/${job_name}" --all-containers=true --tail=50 >&2 || true
            RESULTS+=("FAIL|${pattern}|0|k6 job timeout")
        fi
        cleanup_one "${job_name}"
        rm -f "${baseline_file}"
        return
    fi

    # PHP stacks flush self-call child spans late: symfony redundant_sql regularly burns 4 of
    # the old 6 attempts, laravel redundant_http exhausted them in run 31368007598 (issue #101).
    sleep 15
    # trace_ttl_ms is 30s, so the last requests of a run are only analysed at k6+30s;
    # 18 attempts leave ~100s of margin for the daemon analysis queue under load.
    attempts=18
    for attempt in $(seq "${attempts}"); do
        if ! findings_json="$(daemon_curl -fsS "${DAEMON_URL}/api/findings?limit=10000&include_acked=true")"; then
            RESULTS+=("FAIL|${pattern}|0|daemon findings unavailable")
            break
        fi
        evaluation="$(evaluate_findings "${pattern}" "${endpoint}" "${baseline_file}" "${started_at_ms}" "${expected_framework}" "${expected_recommendation}" "${findings_json}")"
        count="${evaluation%%|*}"
        note="${evaluation#*|}"
        if [ "${count}" = "-1" ]; then
            RESULTS+=("FAIL|${pattern}|0|${note}")
            break
        elif [ "${count}" -ge 1 ]; then
            RESULTS+=("PASS|${pattern}|${count}|${note}")
            break
        elif [ "${attempt}" -eq "${attempts}" ]; then
            color_red "    no finding matched; k6 summary follows"
            kubectl -n "${NAMESPACE}" logs "job/${job_name}" --all-containers=true --tail=50 >&2 || true
            RESULTS+=("FAIL|${pattern}|0|${note}")
        else
            sleep 5
        fi
    done
    cleanup_one "${job_name}"
    rm -f "${baseline_file}"
}

print_summary() {
    local pass=0 fail=0 line status pattern count note
    {
        echo "# multistack validation report — ${SERVICE}${MODE:+ (${MODE})}"
        echo; echo "Run: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo "Daemon: ${DAEMON_URL}"; echo
        echo "| Result | Anti-pattern | Count | Evidence |"; echo "| --- | --- | --- | --- |"
    } > "${REPORT}"
    for line in "${RESULTS[@]}"; do
        IFS='|' read -r status pattern count note <<<"${line}"
        [ "${status}" = PASS ] && pass=$((pass + 1)) || fail=$((fail + 1))
        echo "| ${status} | ${pattern} | ${count} | ${note} |" >> "${REPORT}"
        printf '%-6s %-22s %-7s %s\n' "${status}" "${pattern}" "${count}" "${note}"
    done
    echo >> "${REPORT}"
    echo "${pass} PASS / $((pass + fail)) anti-patterns detected for ${SERVICE}." >> "${REPORT}"
    echo "Report: ${REPORT}"
    [ "${fail}" -eq 0 ]
}

probe_daemon
for spec in "${ANTI_PATTERNS[@]}"; do
    IFS=: read -r pattern vus duration <<<"${spec}"
    run_one "${pattern}" "${vus}" "${duration}"
done
kubectl -n "${NAMESPACE}" delete configmap "k6-${SERVICE}-script" --ignore-not-found >/dev/null
print_summary
