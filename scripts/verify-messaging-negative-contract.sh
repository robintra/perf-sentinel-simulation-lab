#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $(basename "$0") <stack>" >&2
    exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
STACK="$1"

case "${STACK}" in
    quarkus)
        mvn -B -ntp -f services/quarkus-svc/pom.xml -Dtest=MessagingInvalidContractTest test
        ;;
    mutiny)
        mvn -B -ntp -f services/mutiny-svc/pom.xml -Dtest=MessagingInvalidContractTest test
        ;;
    helidon-se)
        mvn -B -ntp -f services/helidon-se-svc/pom.xml -Dtest=MessagingInvalidContractTest test
        ;;
    helidon-mp)
        mvn -B -ntp -f services/helidon-mp-svc/pom.xml -Dtest=MessagingInvalidContractTest test
        ;;
    ktor)
        mvn -B -ntp -f services/ktor-svc/pom.xml -Dtest=ApplicationTest#messagingInvalidContract -Dsurefire.failIfNoSpecifiedTests=true test
        ;;
    django)
        docker build -t django-svc:plan-check services/django-svc
        docker run --rm --entrypoint python django-svc:plan-check -m unittest djangosvc.tests.test_messaging_invalid_contract
        ;;
    fastapi)
        docker build -t fastapi-svc:plan-check services/fastapi-svc
        docker run --rm --entrypoint python fastapi-svc:plan-check -m unittest app.test_messaging_invalid_contract
        ;;
    laravel)
        docker build -t laravel-svc:plan-check services/laravel-svc
        docker run --rm --entrypoint php laravel-svc:plan-check /app/tests/messaging-invalid-contract.php
        ;;
    symfony)
        docker build -t symfony-svc:plan-check services/symfony-svc
        docker run --rm --entrypoint php symfony-svc:plan-check /app/tests/messaging-invalid-contract.php
        ;;
    diesel)
        cargo test --manifest-path services/diesel-svc/Cargo.toml messaging_invalid_contract
        ;;
    seaorm)
        cargo test --manifest-path services/seaorm-svc/Cargo.toml messaging_invalid_contract
        ;;
    rails)
        docker build -t rails-svc:plan-check services/rails-svc
        docker run --rm -e RAILS_ENV=test -e OTEL_SDK_DISABLED=true rails-svc:plan-check bin/rails test test/controllers/messaging_invalid_contract_test.rb
        ;;
    nest)
        npm run test:messaging-negative --prefix services/nest-svc
        ;;
    dotnet)
        dotnet restore services/dotnet-svc/DotnetSvc.csproj --locked-mode
        dotnet restore services/dotnet-svc.tests/DotnetSvc.Tests.csproj --locked-mode
        dotnet test services/dotnet-svc.tests/DotnetSvc.Tests.csproj --no-restore --filter FullyQualifiedName~MessagingInvalidContract
        ;;
    go)
        go -C services/go-svc test ./internal/web -run '^TestMessagingInvalidContract$'
        ;;
    *)
        echo "unknown stack: ${STACK}" >&2
        exit 2
        ;;
esac

echo "PASS: 7/7 HTTP 400, messaging boundary calls 0 (${STACK})"
