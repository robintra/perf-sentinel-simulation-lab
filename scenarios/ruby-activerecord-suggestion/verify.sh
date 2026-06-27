#!/usr/bin/env bash
# ruby-activerecord-suggestion: validate the 0.9.2 Ruby/ActiveRecord
# framework-aware suggestions (detect/suggestions.rs).
#
#   rails-shop     A SANITIZED N+1 (`SELECT * FROM orders WHERE id = $1`, params
#                  empty) whose SQL spans carry the OTel scope
#                  `OpenTelemetry::Instrumentation::ActiveRecord`. Under the
#                  lab's strict sanitizer-aware mode the ORM scope + timing
#                  variance reclassify it to n_plus_one_sql, and the finding is
#                  enriched with suggested_fix.framework = ruby_active_record
#                  (recommendation mentions includes/preload/eager_load).
#   rails-generic  A standard N+1 with no ORM scope but code.filepath ending in
#                  .rb -> suggested_fix.framework = ruby_generic.
#
# Instrumentation scopes are captured ONLY at OTLP ingestion (Jaeger/Zipkin
# carry none), so this is OTLP/protobuf to /v1/traces.
#
# Self-contained: needs only the local release binary; launches a throwaway
# loopback daemon in the lab's strict detection mode.
set -euo pipefail

SCENARIO="ruby-activerecord-suggestion"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIX="${SCRIPT_DIR}/fixtures"
mkdir -p "${TMP_DIR}"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
DAEMON_HTTP_PORT="${DAEMON_HTTP_PORT:-14394}"
DAEMON_GRPC_PORT="${DAEMON_GRPC_PORT:-14395}"
DAEMON_URL="http://127.0.0.1:${DAEMON_HTTP_PORT}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

DAEMON_PID=""
cleanup() { [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true; }
trap cleanup EXIT

[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release -p perf-sentinel first)"

start_local_daemon() {
  pkill -f "perf-sentinel watch.*${DAEMON_HTTP_PORT}" 2>/dev/null || true
  sleep 1
  cat > "${TMP_DIR}/daemon.toml" <<EOF
[daemon]
listen_address = "127.0.0.1"
listen_port_http = ${DAEMON_HTTP_PORT}
listen_port_grpc = ${DAEMON_GRPC_PORT}
api_enabled = true
trace_ttl_ms = 1500

[daemon.ack]
enabled = false

[detection]
n_plus_one_min_occurrences = 5
sanitizer_aware_classification = "strict"
EOF
  "${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/daemon.toml" > "${TMP_DIR}/daemon.log" 2>&1 &
  DAEMON_PID=$!
  for _ in $(seq 1 40); do
    curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}

# Assert a suggested_fix.framework for a service. $1=service $2=expected framework
# $3=substring the recommendation must contain. Prints the recommendation.
assert_suggestion() {
  curl -fsS "${DAEMON_URL}/api/findings" | python3 -c "
import sys, json
items = json.load(sys.stdin)
items = items if isinstance(items, list) else items.get('findings', [])
def u(it): return it.get('finding', it) if isinstance(it, dict) else {}
ours = [u(it) for it in items if u(it).get('service') == '$1' and u(it).get('type') == 'n_plus_one_sql']
assert ours, 'no n_plus_one_sql finding for $1 (types=%s)' % [u(it).get('type') for it in items if u(it).get('service')=='$1']
fixes = [f.get('suggested_fix') for f in ours if f.get('suggested_fix')]
assert fixes, 'finding for $1 carries no suggested_fix'
fw = fixes[0].get('framework')
assert fw == '$2', 'framework=%r, expected $2' % fw
rec = fixes[0].get('recommendation', '')
assert '$3' in rec, 'recommendation lacks \"$3\": %r' % rec
print(rec)
"
}

step "Launch strict-mode daemon and POST the ActiveRecord + generic fixtures"
start_local_daemon || die "daemon not ready on ${DAEMON_URL}: $(tail -3 "${TMP_DIR}/daemon.log")"
for f in ruby-ar.pb ruby-generic.pb; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST "${DAEMON_URL}/v1/traces" \
    -H 'Content-Type: application/x-protobuf' --data-binary @"${FIX}/${f}")"
  [ "${code}" = "200" ] || die "${f}: OTLP POST returned ${code}"
done
sleep 4
ok "both fixtures ingested"

step "ActiveRecord scope -> suggested_fix.framework = ruby_active_record"
AR_REC="$(assert_suggestion rails-shop ruby_active_record includes)" \
  || die "rails-shop: ${AR_REC:-assertion failed}"
ok "rails-shop: ruby_active_record — \"${AR_REC}\""

step ".rb code_location -> suggested_fix.framework = ruby_generic"
GEN_REC="$(assert_suggestion rails-generic ruby_generic '`where(id: ids)`')" \
  || die "rails-generic: ${GEN_REC:-assertion failed}"
ok "rails-generic: ruby_generic — \"${GEN_REC}\""

# =============================================================================
verdict="PASS"
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "| service | classification | suggested_fix.framework |"
  echo "|---|---|---|"
  echo "| rails-shop (ActiveRecord scope, sanitized N+1, strict) | n_plus_one_sql | ruby_active_record |"
  echo "| rails-generic (.rb code.filepath, no scope) | n_plus_one_sql | ruby_generic |"
  echo ""
  echo "- AR recommendation: ${AR_REC}"
  echo "- generic recommendation: ${GEN_REC}"
  echo ""
  echo "Verdict: **${verdict}**"
} > "${REPORT}"
color_green "PASS — report at ${REPORT}"
