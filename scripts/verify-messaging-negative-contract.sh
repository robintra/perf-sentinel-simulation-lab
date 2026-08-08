#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $(basename "$0") <stack>" >&2
    exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
STACK="$1"

require_focused_test() {
    local file="$1" name="${2:-}"
    local required_case='/api/fault/n-plus-one-messaging?messages=4&broker=rabbitmq'
    if [ ! -f "${file}" ] || ! grep -Fq "${required_case}" "${file}" || \
            { [ -n "${name}" ] && ! grep -Fq "${name}" "${file}"; }; then
        echo "missing focused test ${name:-$file} in ${file}" >&2
        exit 1
    fi
}

case "${STACK}" in
    quarkus)
        require_focused_test services/quarkus-svc/src/test/java/com/perfsim/quarkussvc/web/MessagingInvalidContractTest.java MessagingInvalidContractTest
        mvn -B -ntp -f services/quarkus-svc/pom.xml -Dtest=MessagingInvalidContractTest test
        ;;
    mutiny)
        require_focused_test services/mutiny-svc/src/test/java/com/perfsim/mutinysvc/web/MessagingInvalidContractTest.java MessagingInvalidContractTest
        mvn -B -ntp -f services/mutiny-svc/pom.xml -Dtest=MessagingInvalidContractTest test
        ;;
    helidon-se)
        require_focused_test services/helidon-se-svc/src/test/java/com/perfsim/helidonsesvc/web/MessagingInvalidContractTest.java MessagingInvalidContractTest
        mvn -B -ntp -f services/helidon-se-svc/pom.xml -Dtest=MessagingInvalidContractTest test
        ;;
    helidon-mp)
        require_focused_test services/helidon-mp-svc/src/test/java/com/perfsim/helidonmpsvc/web/MessagingInvalidContractTest.java MessagingInvalidContractTest
        mvn -B -ntp -f services/helidon-mp-svc/pom.xml -Dtest=MessagingInvalidContractTest test
        ;;
    ktor)
        require_focused_test services/ktor-svc/src/test/kotlin/com/perfsim/ktor/ApplicationTest.kt messagingInvalidContract
        mvn -B -ntp -f services/ktor-svc/pom.xml -Dtest=ApplicationTest#messagingInvalidContract -Dsurefire.failIfNoSpecifiedTests=true test
        ;;
    django)
        require_focused_test services/django-svc/djangosvc/tests/test_messaging_invalid_contract.py
        docker build -t django-svc:plan-check services/django-svc
        docker run --rm --entrypoint python django-svc:plan-check -m unittest djangosvc.tests.test_messaging_invalid_contract
        ;;
    fastapi)
        require_focused_test services/fastapi-svc/app/test_messaging_invalid_contract.py
        docker build -t fastapi-svc:plan-check services/fastapi-svc
        docker run --rm --entrypoint python fastapi-svc:plan-check -m unittest app.test_messaging_invalid_contract
        ;;
    laravel)
        require_focused_test services/laravel-svc/overlay/tests/messaging-invalid-contract.php
        docker build -t laravel-svc:plan-check services/laravel-svc
        docker run --rm --entrypoint php laravel-svc:plan-check /app/tests/messaging-invalid-contract.php
        ;;
    symfony)
        require_focused_test services/symfony-svc/overlay/tests/messaging-invalid-contract.php
        docker build -t symfony-svc:plan-check services/symfony-svc
        docker run --rm --entrypoint php symfony-svc:plan-check /app/tests/messaging-invalid-contract.php
        ;;
    diesel)
        require_focused_test services/diesel-svc/src/main.rs messaging_invalid_contract
        cargo test --manifest-path services/diesel-svc/Cargo.toml messaging_invalid_contract
        ;;
    seaorm)
        require_focused_test services/seaorm-svc/src/main.rs messaging_invalid_contract
        cargo test --manifest-path services/seaorm-svc/Cargo.toml messaging_invalid_contract
        ;;
    rails)
        require_focused_test services/rails-svc/test/controllers/messaging_invalid_contract_test.rb
        docker build -t rails-svc:plan-check services/rails-svc
        docker run --rm -e RAILS_ENV=test -e OTEL_SDK_DISABLED=true rails-svc:plan-check bin/rails test test/controllers/messaging_invalid_contract_test.rb
        ;;
    nest)
        require_focused_test services/nest-svc/src/fault/messaging-invalid-contract.spec.ts
        npm run test:messaging-negative --prefix services/nest-svc
        ;;
    dotnet)
        require_focused_test services/dotnet-svc.tests/MessagingInvalidContractTests.cs MessagingInvalidContract
        dotnet restore services/dotnet-svc/DotnetSvc.csproj --locked-mode
        dotnet restore services/dotnet-svc.tests/DotnetSvc.Tests.csproj --locked-mode
        dotnet test services/dotnet-svc.tests/DotnetSvc.Tests.csproj --no-restore --filter FullyQualifiedName~MessagingInvalidContract
        ;;
    go)
        require_focused_test services/go-svc/internal/web/messaging_invalid_contract_test.go TestMessagingInvalidContract
        go -C services/go-svc test ./internal/web -run '^TestMessagingInvalidContract$'
        ;;
    *)
        echo "unknown stack: ${STACK}" >&2
        exit 2
        ;;
esac

echo "PASS: 7/7 HTTP 400, messaging boundary calls 0 (${STACK})"
