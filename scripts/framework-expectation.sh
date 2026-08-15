#!/usr/bin/env bash
# Shared PHP framework/recommendation expectation map for the multistack matchers:
# scripts/run-multistack-scenario.sh (the release gate) and
# scripts/validate-findings-multistack.sh (the standalone validator). Single source
# of truth so the two never drift. No top-level side effects, only a function
# definition, so the file is safe to source more than once.
#
# framework_expectation <stack> <pattern>  ->  prints "<framework>|<rec-alt1||rec-alt2>"
#
# Empty output = no framework/recommendation assertion for this (stack,pattern):
# the finding is validated on type+service only (unchanged behaviour, so every
# non-PHP stack and the structural PHP anti-patterns keep passing untouched).
#
# The PHP maps below were validated end-to-end (local loopback + in-cluster):
#  - laravel: the app-wide io.opentelemetry.contrib.php.laravel scope rides the
#    whole request, so SQL and point-HTTP findings all carry php_laravel_eloquent.
#  - symfony: the DB-specific io.opentelemetry.contrib.php.doctrine scope tags only
#    SQL findings (php_doctrine); HTTP findings see only php.symfony and fall through
#    to php_generic.
#  - The structural anti-patterns (excessive_fanout, chatty_service, serialized_calls,
#    pool_saturation) carry no code_location / scope chain in the daemon, so no
#    framework tag is emitted for them in any stack -> no assertion here.
#  - slow_sql / slow_http and laravel's redundant_sql tag inconsistently (the
#    self-call child spans race the async flush), so they are matched on type+service
#    only. n_plus_one_sql, n_plus_one_http and redundant_http tag deterministically,
#    which already covers the required mapping (SQL N+1 + a non-SQL finding per svc).
#  - Only the two PHP stacks are mapped. The mechanism generalises to ruby_active_record
#    / java_jpa once their exact recommendation strings are confirmed against a live run.
# `|` separates framework from the recommendation-substring list; `||` separates
# acceptable substrings (any one match passes).
framework_expectation() {
    local stack="$1" pattern="$2"
    case "${stack}:${pattern}" in
        laravel:n_plus_one_sql)
            echo "php_laravel_eloquent|with(||load(" ;;
        laravel:n_plus_one_http|laravel:redundant_http)
            echo "php_laravel_eloquent|" ;;
        symfony:n_plus_one_sql)
            echo "php_doctrine|leftJoin||addSelect||fetch" ;;
        symfony:n_plus_one_http|symfony:redundant_http)
            echo "php_generic|" ;;
        *)
            echo "" ;;
    esac
}
