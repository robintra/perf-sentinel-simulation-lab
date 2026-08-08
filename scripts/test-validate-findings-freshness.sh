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
