#!/usr/bin/env bash
# Multistack validator. For a given <stack>-svc, polls the daemon's
# /api/findings and asserts at least one finding per anti-pattern type
# tagged with `service = <stack>-svc`. The expected anti-pattern list
# matches the Java baseline (`scripts/validate-findings.sh`): each
# multistack service is expected to reproduce all 10 anti-patterns in
# its own runtime, see docs/MULTISTACK.md.
#
# Unlike `validate-findings.sh`, this script does NOT drive k6 itself.
# Each <stack>-svc ships its own composite k6 scenario at
# `scenarios/<stack>-svc-validation.js` that fires the 10 fault
# endpoints. Run that scenario first, then this script to grade the
# findings.
#
# Usage:
#   scripts/validate-findings-multistack.sh <stack>-svc
#
# Exit code: 0 if all 10 anti-patterns are detected for the service,
# 1 otherwise. Writes tmp/validation-report-<stack>-svc.md.
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $(basename "$0") <stack>-svc" >&2
    echo "       e.g. $(basename "$0") quarkus-svc" >&2
    exit 2
fi

SERVICE="$1"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

DAEMON_URL="${DAEMON_URL:-http://localhost:14318}"
TMP_DIR="${REPO_ROOT}/tmp"
REPORT="${TMP_DIR}/validation-report-${SERVICE}.md"
mkdir -p "${TMP_DIR}"

color_blue()   { printf "\033[34m%s\033[0m\n" "$*"; }
color_green()  { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()    { printf "\033[31m%s\033[0m\n" "$*"; }
color_yellow() { printf "\033[33m%s\033[0m\n" "$*"; }

# The 10 anti-patterns every multistack service is contracted to produce.
# Order matches docs/MULTISTACK.md.
ANTI_PATTERNS=(
    "n_plus_one_sql"
    "n_plus_one_http"
    "redundant_sql"
    "redundant_http"
    "slow_sql"
    "slow_http"
    "excessive_fanout"
    "chatty_service"
    "serialized_calls"
    "pool_saturation"
)

declare -a RESULTS

# PHP framework/recommendation expectations — single source of truth, shared with
# scripts/run-multistack-scenario.sh (defines framework_expectation()).
. "${REPO_ROOT}/scripts/framework-expectation.sh"

probe_daemon() {
    local max_probe_attempts=5 probe_sleep_s=2 attempt=1
    while [ "${attempt}" -le "${max_probe_attempts}" ]; do
        if curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1; then
            return 0
        fi
        if [ "${attempt}" -eq "${max_probe_attempts}" ]; then
            color_red "daemon not reachable at ${DAEMON_URL} after ${max_probe_attempts} attempts, run scripts/port-forward.sh start"
            exit 1
        fi
        color_yellow "daemon probe attempt ${attempt}/${max_probe_attempts} failed, retrying in ${probe_sleep_s}s"
        sleep "${probe_sleep_s}"
        attempt=$((attempt + 1))
    done
}

count_findings() {
    local pattern="$1" findings_json="$2"
    printf "%s" "${findings_json}" \
        | EXPECTED_TYPE="${pattern}" EXPECTED_SERVICE="${SERVICE}" \
          EXPECTED_FRAMEWORK="${EXPECTED_FRAMEWORK:-}" EXPECTED_REC="${EXPECTED_REC:-}" \
          python3 -c "
import json, os, sys
try:
    items = json.load(sys.stdin)
except json.JSONDecodeError:
    print(-1); sys.exit(0)
expected_type = os.environ['EXPECTED_TYPE']
expected_service = os.environ['EXPECTED_SERVICE']
expected_fw = os.environ.get('EXPECTED_FRAMEWORK', '')
expected_rec = os.environ.get('EXPECTED_REC', '')
def unwrap(it):
    return it.get('finding', it) if isinstance(it, dict) else {}
def matches(f):
    if f.get('type') != expected_type or f.get('service') != expected_service:
        return False
    if expected_fw:
        sf = f.get('suggested_fix') or {}
        if sf.get('framework') != expected_fw:
            return False
        if expected_rec:
            rec = sf.get('recommendation') or ''
            if not any(sub in rec for sub in expected_rec.split('||')):
                return False
    return True
matched = [f for it in items if matches(f := unwrap(it))]
print(len(matched))
" 2>/dev/null || echo -1
}

grade_service() {
    color_blue "==> grading ${SERVICE} against the 10 multistack anti-patterns"

    local findings_json
    if ! findings_json="$(curl -fsS "${DAEMON_URL}/api/findings" 2>&1)"; then
        color_red "    daemon /api/findings unreachable"
        for pattern in "${ANTI_PATTERNS[@]}"; do
            RESULTS+=("FAIL|${pattern}|0|daemon /api/findings unreachable")
        done
        return
    fi

    local stack="${SERVICE%-svc}"
    local pattern count expectation exp_fw exp_rec fw_note
    for pattern in "${ANTI_PATTERNS[@]}"; do
        expectation="$(framework_expectation "${stack}" "${pattern}")"
        exp_fw="${expectation%%|*}"
        if [ "${expectation}" = "${exp_fw}" ]; then exp_rec=""; else exp_rec="${expectation#*|}"; fi
        fw_note=""
        [ -n "${exp_fw}" ] && fw_note=" framework=${exp_fw}"
        count="$(EXPECTED_FRAMEWORK="${exp_fw}" EXPECTED_REC="${exp_rec}" \
                 count_findings "${pattern}" "${findings_json}")"
        if [ "${count}" = "-1" ]; then
            RESULTS+=("FAIL|${pattern}|0|daemon returned malformed JSON")
        elif [ "${count:-0}" -ge 1 ]; then
            color_green "    PASS ${pattern} (${count} matching findings${fw_note})"
            RESULTS+=("PASS|${pattern}|${count}|${fw_note# }")
        else
            color_red "    FAIL ${pattern} (0 matching findings${fw_note})"
            RESULTS+=("FAIL|${pattern}|0|no finding of this type tagged service=${SERVICE}${fw_note}")
        fi
    done
}

print_summary() {
    local pass=0 fail=0
    {
        echo "# multistack validation report — ${SERVICE}"
        echo
        echo "Run: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "Daemon: ${DAEMON_URL}"
        echo
        echo "| Result | Anti-pattern | Count | Note |"
        echo "| --- | --- | --- | --- |"
    } > "${REPORT}"

    echo
    color_blue "=== multistack validation results — ${SERVICE} ==="
    printf "%-6s %-22s %-7s %s\n" "STATUS" "ANTI-PATTERN" "COUNT" "NOTE"

    for line in "${RESULTS[@]}"; do
        IFS='|' read -r status ftype count note <<<"${line}"
        if [ "${status}" = "PASS" ]; then
            pass=$((pass + 1))
            printf "\033[32m%-6s\033[0m %-22s %-7s %s\n" "${status}" "${ftype}" "${count}" "${note}"
        else
            fail=$((fail + 1))
            printf "\033[31m%-6s\033[0m %-22s %-7s %s\n" "${status}" "${ftype}" "${count}" "${note}"
        fi
        echo "| ${status} | ${ftype} | ${count} | ${note} |" >> "${REPORT}"
    done

    {
        echo
        echo "## Score"
        echo
        echo "${pass} PASS / $((pass + fail)) anti-patterns detected for ${SERVICE}."
    } >> "${REPORT}"

    echo
    color_blue "Score: ${pass} / $((pass + fail)) anti-patterns detected for ${SERVICE}"
    color_blue "Report: ${REPORT}"

    if [ "${fail}" -gt 0 ]; then
        return 1
    fi
    return 0
}

probe_daemon
grade_service
print_summary
