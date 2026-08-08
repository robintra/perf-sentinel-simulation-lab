#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "${TEST_TMP}"' EXIT

if [[ "${1:-}" == "--live" ]]; then
    source "${REPO_ROOT}/scripts/validate-findings.sh"
    broken_scenario="${TEST_TMP}/n-plus-one-messaging-broken.js"
    sed 's/order-service\.shop\.svc\.cluster\.local/order-service-broken.shop.svc.cluster.local/' \
        "${REPO_ROOT}/scenarios/n-plus-one-messaging.js" > "${broken_scenario}"

    RESULTS=()
    run_scenario n-plus-one-messaging n_plus_one_messaging order-service \
        scenarios/n-plus-one-messaging.js /api/fault/n-plus-one-messaging
    [[ "${RESULTS[0]}" == PASS\|n-plus-one-messaging\|* ]] || {
        echo "FAIL: could not preload a real n_plus_one_messaging finding: ${RESULTS[0]}"
        exit 1
    }

    RESULTS=()
    run_scenario n-plus-one-messaging n_plus_one_messaging order-service \
        "${broken_scenario}" /api/fault/n-plus-one-messaging
    [[ "${RESULTS[0]}" == FAIL\|n-plus-one-messaging\|* ]] || {
        echo "FAIL: broken endpoint reused a stale finding: ${RESULTS[0]}"
        exit 1
    }

    RESULTS=()
    run_scenario n-plus-one-messaging n_plus_one_messaging order-service \
        scenarios/n-plus-one-messaging.js /api/fault/n-plus-one-messaging
    [[ "${RESULTS[0]}" == PASS\|n-plus-one-messaging\|* ]] || {
        echo "FAIL: restored endpoint did not produce a fresh finding: ${RESULTS[0]}"
        exit 1
    }

    echo "PASS: broken endpoint fails despite history; restored endpoint passes on a fresh trace"
    exit 0
fi

mkdir -p "${TEST_TMP}/bin" "${TEST_TMP}/gate"

cat > "${TEST_TMP}/bin/kubectl" <<'SH'
#!/usr/bin/env bash
if [[ " $* " == *" create configmap "* ]]; then
    printf 'apiVersion: v1\n'
fi
SH

cat > "${TEST_TMP}/bin/sleep" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == 1 ]]; then
    /bin/sleep 0.05
fi
exit 0
SH

cat > "${TEST_TMP}/old.json" <<'JSON'
[{"finding":{"type":"slow_messaging","service":"order-service","source_endpoint":"/api/fault/slow-messaging","trace_id":"old-trace"},"stored_at_ms":1}]
JSON

cat > "${TEST_TMP}/stale.json" <<'JSON'
[
  {"finding":{"type":"slow_messaging","service":"order-service","source_endpoint":"/api/fault/slow-messaging","trace_id":"old-trace"},"stored_at_ms":9999999999999},
  {"finding":{"type":"slow_messaging","service":"order-service","source_endpoint":"/api/fault/slow-messaging","trace_id":"pre-start-trace"},"stored_at_ms":1},
  {"finding":{"type":"slow_messaging","service":"order-service","source_endpoint":"/wrong-endpoint","trace_id":"wrong-endpoint-trace"},"stored_at_ms":9999999999999}
]
JSON

cat > "${TEST_TMP}/fresh.json" <<'JSON'
[
  {"finding":{"type":"slow_messaging","service":"order-service","source_endpoint":"/api/fault/slow-messaging","trace_id":"old-trace"},"stored_at_ms":9999999999999},
  {"finding":{"type":"slow_messaging","service":"order-service","source_endpoint":"/api/fault/slow-messaging","trace_id":"pre-start-trace"},"stored_at_ms":1},
  {"finding":{"type":"slow_messaging","service":"order-service","source_endpoint":"/wrong-endpoint","trace_id":"wrong-endpoint-trace"},"stored_at_ms":9999999999999},
  {"finding":{"type":"slow_messaging","service":"order-service","source_endpoint":"/api/fault/slow-messaging","trace_id":"fresh-trace"},"stored_at_ms":9999999999999}
]
JSON

cat > "${TEST_TMP}/bin/curl" <<'SH'
#!/usr/bin/env bash
count="$(cat "${CURL_COUNT_FILE}")"
printf '%s\n' "$((count + 1))" > "${CURL_COUNT_FILE}"
if [[ "${count}" -eq 0 ]]; then
    cat "${OLD_FINDINGS_FILE}"
elif [[ "${FINDINGS_MODE}" == "fresh" ]]; then
    cat "${FRESH_FINDINGS_FILE}"
else
    cat "${STALE_FINDINGS_FILE}"
fi
SH

chmod +x "${TEST_TMP}/bin/kubectl" "${TEST_TMP}/bin/sleep" "${TEST_TMP}/bin/curl"
export PATH="${TEST_TMP}/bin:${PATH}"
export CURL_COUNT_FILE="${TEST_TMP}/curl-count"
export OLD_FINDINGS_FILE="${TEST_TMP}/old.json"
export STALE_FINDINGS_FILE="${TEST_TMP}/stale.json"
export FRESH_FINDINGS_FILE="${TEST_TMP}/fresh.json"

source "${REPO_ROOT}/scripts/validate-findings.sh"
TMP_DIR="${TEST_TMP}/gate"
REPORT="${TMP_DIR}/validation-report.md"

printf '0\n' > "${CURL_COUNT_FILE}"
export FINDINGS_MODE=stale
RESULTS=()
run_scenario slow-messaging slow_messaging order-service \
    scenarios/slow-messaging.js /api/fault/slow-messaging
if [[ "${RESULTS[0]}" != FAIL\|slow-messaging\|* ]]; then
    echo "FAIL: stale finding was accepted: ${RESULTS[0]}"
    exit 1
fi

printf '0\n' > "${CURL_COUNT_FILE}"
export FINDINGS_MODE=fresh
RESULTS=()
run_scenario slow-messaging slow_messaging order-service \
    scenarios/slow-messaging.js /api/fault/slow-messaging
if [[ "${RESULTS[0]}" != PASS\|slow-messaging\|* ]]; then
    echo "FAIL: fresh finding was rejected: ${RESULTS[0]}"
    exit 1
fi

echo "PASS: stale findings fail and a fresh endpoint-matched trace passes"

# Exercise the Task 1 sequential runner itself. A trace observed before the Job
# stays stale even if a later finding reports it under the expected endpoint.
cat > "${TEST_TMP}/bin/kubectl" <<'SH'
#!/usr/bin/env bash
if [[ -n "${RUNNER_KUBECTL_LOG:-}" ]]; then
    printf '%s\n' "$*" >> "${RUNNER_KUBECTL_LOG}"
fi
if [[ " $* " == *" create configmap "* ]]; then
    printf 'apiVersion: v1\n'
elif [[ " $* " == *" wait job/"* ]]; then
    if [[ "${RUNNER_JOB_STATE:-complete}" == failed ]]; then
        if [[ " $* " == *"condition=Failed"* ]]; then exit 0; fi
        /bin/sleep 3
        exit 1
    fi
    if [[ " $* " == *"condition=Complete"* ]]; then exit 0; fi
    /bin/sleep 3
    exit 1
elif [[ " $* " == *" logs job/"* ]]; then
    echo "simulated k6 threshold failure"
fi
SH

cat > "${TEST_TMP}/bin/curl" <<'SH'
#!/usr/bin/env bash
if [[ " $* " == *"/api/status "* ]]; then
    printf '{}\n'
    exit 0
fi
count="$(cat "${RUNNER_CURL_COUNT}")"
printf '%s\n' "$((count + 1))" > "${RUNNER_CURL_COUNT}"
if [[ "${RUNNER_CASE}" == "converging" ]]; then
    case "${count}" in
        0|3) printf '[]\n' ;;
        1) printf '[{"finding":{"type":"n_plus_one_messaging","service":"%s","source_endpoint":"unknown","trace_id":"partial-trace","pattern":{"template":"rabbitmq perfsim.%s","occurrences":8}},"stored_at_ms":9999999999999}]\n' "${RUNNER_SERVICE}" "${RUNNER_SERVICE}" ;;
        2) printf '[{"finding":{"type":"n_plus_one_messaging","service":"%s","source_endpoint":"/api/fault/n-plus-one-messaging","trace_id":"converged-trace","pattern":{"template":"rabbitmq perfsim.%s","occurrences":8}},"stored_at_ms":9999999999999}]\n' "${RUNNER_SERVICE}" "${RUNNER_SERVICE}" ;;
        4) printf '[{"finding":{"type":"slow_messaging","service":"%s","source_endpoint":"/api/fault/slow-messaging","trace_id":"fresh-slow","pattern":{"template":"rabbitmq perfsim.%s","occurrences":3,"span_duration_us_p50":600001}},"stored_at_ms":9999999999999}]\n' "${RUNNER_SERVICE}" "${RUNNER_SERVICE}" ;;
    esac
    exit 0
fi
if [[ $((count % 2)) -eq 0 ]]; then
    case "${RUNNER_CASE}" in
        malformed) printf '{}\n'; exit 0 ;;
        destination) printf '[]\n'; exit 0 ;;
    esac
fi
case "${count}" in
    0) printf '[{"finding":{"trace_id":"reused-n-plus-one","source_endpoint":"/old-endpoint"}}]\n' ;;
    1) printf '[{"finding":{"type":"n_plus_one_messaging","service":"%s","source_endpoint":"/api/fault/n-plus-one-messaging","trace_id":"reused-n-plus-one","pattern":{"template":"rabbitmq perfsim.%s","occurrences":8}},"stored_at_ms":9999999999999}]\n' "${RUNNER_SERVICE}" "${RUNNER_SERVICE}" ;;
    2) printf '[{"finding":{"trace_id":"reused-slow","source_endpoint":"/old-endpoint"}}]\n' ;;
    3) printf '[{"finding":{"type":"slow_messaging","service":"%s","source_endpoint":"/api/fault/slow-messaging","trace_id":"reused-slow","pattern":{"template":"rabbitmq perfsim.%s","occurrences":3,"span_duration_us_p50":600001}},"stored_at_ms":9999999999999}]\n' "${RUNNER_SERVICE}" "${RUNNER_SERVICE}" ;;
esac
SH

chmod +x "${TEST_TMP}/bin/kubectl" "${TEST_TMP}/bin/curl"
export RUNNER_CURL_COUNT="${TEST_TMP}/runner-curl-count"
export RUNNER_KUBECTL_LOG="${TEST_TMP}/runner-kubectl.log"
export VALIDATION_TMP_DIR="${TEST_TMP}/runner"
mkdir -p "${VALIDATION_TMP_DIR}"
: > "${RUNNER_KUBECTL_LOG}"
export RUNNER_SERVICE=quarkus-svc
export RUNNER_JOB_STATE=complete
export RUNNER_CASE=stale
printf '0\n' > "${RUNNER_CURL_COUNT}"
if "${REPO_ROOT}/scripts/run-multistack-scenario.sh" quarkus messaging \
        > "${TEST_TMP}/runner-stale.log" 2>&1; then
    echo "FAIL: runner accepted a trace ID already present under another endpoint"
    exit 1
fi

echo "PASS: runner rejects a trace ID already present under another endpoint"

export RUNNER_CASE=malformed
printf '0\n' > "${RUNNER_CURL_COUNT}"
if "${REPO_ROOT}/scripts/run-multistack-scenario.sh" quarkus messaging \
        > "${TEST_TMP}/runner-malformed.log" 2>&1; then
    echo "FAIL: runner accepted a non-list daemon response"
    exit 1
fi

echo "PASS: runner rejects a non-list daemon response"

export RUNNER_CASE=destination
export RUNNER_SERVICE=mutiny-svc
printf '0\n' > "${RUNNER_CURL_COUNT}"
if ! "${REPO_ROOT}/scripts/run-multistack-scenario.sh" mutiny messaging \
        > "${TEST_TMP}/runner-destination.log" 2>&1; then
    echo "FAIL: runner rejected the destination derived from another service slug"
    cat "${TEST_TMP}/runner-destination.log"
    exit 1
fi

echo "PASS: runner derives the RabbitMQ destination from the service slug"

export RUNNER_CASE=converging
export RUNNER_SERVICE=quarkus-svc
printf '0\n' > "${RUNNER_CURL_COUNT}"
if ! "${REPO_ROOT}/scripts/run-multistack-scenario.sh" quarkus messaging \
        > "${TEST_TMP}/runner-converging.log" 2>&1; then
    echo "FAIL: runner did not wait for the complete fresh trace/source finding"
    cat "${TEST_TMP}/runner-converging.log"
    exit 1
fi

echo "PASS: runner waits for a complete fresh trace/source finding"

export RUNNER_CASE=destination
export RUNNER_SERVICE=quarkus-svc
export RUNNER_JOB_STATE=failed
printf '0\n' > "${RUNNER_CURL_COUNT}"
: > "${RUNNER_KUBECTL_LOG}"
SECONDS=0
if "${REPO_ROOT}/scripts/run-multistack-scenario.sh" quarkus messaging \
        > "${TEST_TMP}/runner-job-failed.log" 2>&1; then
    echo "FAIL: runner accepted a failed k6 Job"
    cat "${RUNNER_KUBECTL_LOG}"
    exit 1
fi
if [[ "${SECONDS}" -ge 2 ]]; then
    echo "FAIL: runner waited ${SECONDS}s before diagnosing a failed k6 Job"
    exit 1
fi
if ! grep -q 'simulated k6 threshold failure' "${TEST_TMP}/runner-job-failed.log"; then
    echo "FAIL: runner did not report the failed k6 Job logs"
    cat "${TEST_TMP}/runner-job-failed.log"
    cat "${RUNNER_KUBECTL_LOG}"
    exit 1
fi
if [[ ! -f "${VALIDATION_TMP_DIR}/validation-report-quarkus-svc-messaging.md" ]]; then
    echo "FAIL: runner ignored the isolated validation report directory"
    exit 1
fi

echo "PASS: runner diagnoses a failed k6 Job immediately with pod logs"
