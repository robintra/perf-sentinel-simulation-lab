#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "${TEST_TMP}"' EXIT
mkdir -p "${TEST_TMP}/bin"

cat > "${TEST_TMP}/bin/mvn" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${MVN_CALL_LOG}"
SH

cat > "${TEST_TMP}/bin/kubectl" <<'SH'
#!/usr/bin/env bash
exit 0
SH

chmod +x "${TEST_TMP}/bin/mvn" "${TEST_TMP}/bin/kubectl"
export PATH="${TEST_TMP}/bin:${PATH}"
export MVN_CALL_LOG="${TEST_TMP}/mvn-call.log"

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

echo "PASS: negative-contract helper dispatches Quarkus natively and rejects unknown slugs"
