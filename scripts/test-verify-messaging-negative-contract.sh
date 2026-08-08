#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "${TEST_TMP}"' EXIT
mkdir -p "${TEST_TMP}/bin"

cat > "${TEST_TMP}/bin/mvn" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${MVN_CALL_LOG}"
printf '%s\n' "${NATIVE_OUTPUT:-}"
SH

cat > "${TEST_TMP}/bin/cargo" <<'SH'
#!/usr/bin/env bash
: > "${NATIVE_CALL_LOG}"
SH

cat > "${TEST_TMP}/bin/go" <<'SH'
#!/usr/bin/env bash
: > "${NATIVE_CALL_LOG}"
SH

cat > "${TEST_TMP}/bin/kubectl" <<'SH'
#!/usr/bin/env bash
exit 0
SH

chmod +x "${TEST_TMP}/bin/mvn" "${TEST_TMP}/bin/cargo" "${TEST_TMP}/bin/go" "${TEST_TMP}/bin/kubectl"
export PATH="${TEST_TMP}/bin:${PATH}"
export MVN_CALL_LOG="${TEST_TMP}/mvn-call.log"
export NATIVE_CALL_LOG="${TEST_TMP}/native-call.log"
MARKER='PERF_SENTINEL_MESSAGING_NEGATIVE_CONTRACT_PASS 7/7 boundary_calls=0'

export NATIVE_OUTPUT=
if (cd "${REPO_ROOT}" && bash scripts/verify-messaging-negative-contract.sh quarkus) \
        > "${TEST_TMP}/no-marker.log" 2>&1; then
    echo "FAIL: helper accepted native exit 0 without the exact success marker"
    exit 1
fi

export NATIVE_OUTPUT='HTTP 400 1/7'
if (cd "${REPO_ROOT}" && bash scripts/verify-messaging-negative-contract.sh quarkus) \
        > "${TEST_TMP}/one-case.log" 2>&1; then
    echo "FAIL: helper accepted a native runner that executed only one case"
    exit 1
fi

export NATIVE_OUTPUT="${MARKER}"
output="$(cd "${REPO_ROOT}" && bash scripts/verify-messaging-negative-contract.sh quarkus)"
expected='-B -ntp -f services/quarkus-svc/pom.xml -Dtest=MessagingInvalidContractTest test'
if [[ ! -f "${MVN_CALL_LOG}" ]] || [[ "$(cat "${MVN_CALL_LOG}")" != "${expected}" ]]; then
    echo "FAIL: quarkus did not dispatch the exact hermetic Maven test"
    exit 1
fi
if [[ "${output}" != *'PASS: 7/7 HTTP 400, messaging boundary calls 0'* ]]; then
    echo "FAIL: helper output does not report the boundary-spy contract"
    exit 1
fi

set +e
cd "${REPO_ROOT}" && bash scripts/verify-messaging-negative-contract.sh unknown >/dev/null 2>&1
status=$?
set -e
if [[ "${status}" -ne 2 ]]; then
    echo "FAIL: unknown stack exited ${status}, expected 2"
    exit 1
fi

mkdir -p "${TEST_TMP}/repo/scripts" \
    "${TEST_TMP}/repo/services/diesel-svc/src" \
    "${TEST_TMP}/repo/services/seaorm-svc/src" \
    "${TEST_TMP}/repo/services/go-svc/internal/web"
cp "${REPO_ROOT}/scripts/verify-messaging-negative-contract.sh" "${TEST_TMP}/repo/scripts/"
printf '#[test]\nfn messaging_invalid_contract() {}\n' > "${TEST_TMP}/repo/services/diesel-svc/src/main.rs"
printf '#[test]\nfn messaging_invalid_contract() {}\n' > "${TEST_TMP}/repo/services/seaorm-svc/src/main.rs"
printf 'package web\nfunc TestMessagingInvalidContract() {}\n' > "${TEST_TMP}/repo/services/go-svc/internal/web/messaging_invalid_contract_test.go"
for stack in diesel seaorm go; do
    rm -f "${NATIVE_CALL_LOG}"
    if (cd "${TEST_TMP}/repo" && bash scripts/verify-messaging-negative-contract.sh "${stack}") \
            > "${TEST_TMP}/${stack}-missing.log" 2>&1; then
        echo "FAIL: ${stack} accepted a missing focused test"
        exit 1
    fi
    if [[ -e "${NATIVE_CALL_LOG}" ]]; then
        echo "FAIL: ${stack} invoked its native runner before proving the focused test exists"
        exit 1
    fi
done

echo "PASS: negative-contract helper requires the exact native 7/7 boundary marker"
